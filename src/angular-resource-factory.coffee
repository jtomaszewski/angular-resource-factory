app = angular.module "angular-resource-factory", ["DeferredWithMultipleUpdates"]

# ResourceFactory, a helper class from which you can inherit,
# has very useful methods:
#
# 1. #_createApiResource
#
# TODO see if there are any memory leaks?
app.factory "ResourceFactory", (DeferredWithUpdate, CacheService, $http, ENV, BACKEND_URL, Auth, NetworkConnection, $log) ->
  class ResourceFactory
    _getBaseUrl: ->
      "#{BACKEND_URL}/api/v1"


    # Creates a resource for given config, which creates an object which will be updated in-place, after the request will be completed.
    #
    # Also the resource object has following attributes:
    # - .$promise [Promise] - can be resolved once or twice: first time, when resolved from cache, and 2nd time, when resolved from network response
    # - .$networkPromise [Promise] - will be resolved only once, when the network response comes (or rejected it network fails)
    # - .$resolved [Boolean] - has it been resolved with some data (cached or network, doesn't matter)?
    # - .$failed [Boolean] - has the latest network request failed?
    # - .$loading [Boolean] - are we waiting for populating data via cache or network?
    # - .$networkLoading [Boolean] - is the network request currently being loaded?
    # - .$retry() [Function] - you can repeat the network request (in case you'd want to retry the failed request or just update the data in-place)
    # - .$resolveWith(data) [Function] - you can manually resolve .$promise and .$networkPromise with given data object.
    # - .$data [Object] - actual data of the JSON object (useful if you want to serialize it, without unnecessary .$promise and other properties)
    #
    # The options you can pass in into _createApiResource() method are:
    # - $httpParams [Object] - will be passed directly into $http() method
    # - transformResponse [Function] - will be called on response.data before it will be applied to the resource object
    # - isArray [Boolean] - is the response data an object or an array? (default: an object)
    # - cache [Boolean] - should we cache the resource and resolve it with cached data, if exists? (default: true, if GET)
    # - cacheKey [String] - by default, is generated by @_generateCacheKey() based on $httpParams
    # - transformCacheBefore [Function] - transforms the response.data before it'll be saved to CacheService
    # - transformCacheAfter [Function] - transforms the cached data received from CacheService before it will be send to deferredPromise.resolve()
    # - retryifFails [Boolean] - should we .$retry() the network request (if failed), after the NetworkConnection comes back online? (default: true, if :cache)
    _createApiResource: ({$httpParams, transformResponse, isArray, cache, cacheKey, retryIfFails, transformCacheBefore, transformCacheAfter}) ->
      cache ?= $httpParams.method == "GET"
      cacheKey ?= @_generateCacheKey($httpParams.url, $httpParams.params)
      retryIfFails ?= cache
      transformCacheBefore ?= angular.identity
      transformCacheAfter ?= angular.identity
      transformResponse ?= angular.identity
      isArray ?= false

      deferredPromise = DeferredWithUpdate.defer()
      deferredNetworkPromise = DeferredWithUpdate.defer()

      resource = if isArray
        []
      else
        {}

      resource.$promise = deferredPromise.promise
      resource.$networkPromise = deferredNetworkPromise.promise
      resource.$resolved = false
      resource.$failed = false
      resource.$loading = true
      resource.$resolveWith = (data) ->
        # Remove previous values, f.e. added from the cache
        if resource.$data
          if angular.isArray(resource.$data)
            resource.splice(0, resource.length)
          else if angular.isObject(resource.$data)
            for k, v of resource.$data
              delete resource[k]

        resource.$data = data
        extendResourceWithData(data)
        deferredPromise.resolve(data)
        deferredNetworkPromise.resolve(data)

      extendResourceWithData = (data) ->
        angular.extend(resource, data)

        # # If we extend array with an array, we should also extend the array like in object
        # # (f.e. when we have an array [] which has properties like .limit, .offset)
        # if angular.isArray(data)
        #   for [k, v] in _.pairs(data)
        #     resource[k] = v

      if cache && cacheValue = CacheService.forUrl(cacheKey)
        # $log.debug "cacheValue resolved!"
        resource.$resolved = true
        resource.$loading = false

        dataFromCache = transformCacheAfter(angular.copy(cacheValue))

        extendResourceWithData(dataFromCache)
        deferredPromise.resolve(dataFromCache)

      requestServer = ->
        resource.$networkLoading = true

        $http($httpParams)

        .success (data, status, headers, config) ->
          # $log.debug "httpdata resolved!"
          resource.$resolved = true
          resource.$failed = false
          data = transformResponse(data)

          if cache && (ENV == "development" || CacheService.shouldUpdate(cacheKey, headers))
            dataToCache = transformCacheBefore(angular.copy(data))
            CacheService.update(cacheKey, headers, dataToCache)

            resource.$resolveWith(data)
          else
            resource.$resolveWith(data)

        .error (data, status, headers, config) ->
          resource.$failed = true

          deferredPromise.reject({data, status, headers, config})
          deferredNetworkPromise.reject({data, status, headers, config})

        # resource.$promise.then -> $log.debug "$promise resolved!"
        # resource.$networkPromise.then -> $log.debug "$networkPromise resolved!"

        .finally ->
          resource.$loading = false
          resource.$networkLoading = false

      requestServer()
      resource.$retry = -> requestServer()

      if retryIfFails
        # If we failed, then retry after the internet connection comes back.
        unbindRetryCallback = null

        resource.$networkPromise.catch ->
          unbindRetryCallback ||= NetworkConnection.onOnline ->
            resource.$retry() if resource.$failed && !resource.$networkLoading

        resource.$networkPromise.then ->
          if unbindRetryCallback
            unbindRetryCallback()
            unbindRetryCallback = null

      resource


    _generateCacheKey: (url, params) ->
      params = angular.copy(params || {})

      # Remove auth tokens from cacheKey [should we?]
      delete params.auth_token
      delete params.token

      for k, v of params
        params[k] = v.toString() if angular.isNumber(v)

      url + (if _.isEmpty(params) then "" else JSON.stringify(params))
