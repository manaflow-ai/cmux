import Foundation

private let browserFaviconStoreDefaultMaxIconCacheEntries = 512
private let browserFaviconStoreDefaultMaxOriginCacheEntries = 1_024

actor BrowserFaviconStore {
    typealias Fetch = @Sendable () async -> Data?

    private struct InFlightResolution {
        let id: UUID
        let task: Task<Data?, Never>
    }

    private let maxIconCacheEntries: Int
    private let maxOriginCacheEntries: Int
    private var pngDataByIconCacheKey: [String: Data] = [:]
    private var iconURLStringByOriginCacheKey: [String: String] = [:]
    private var iconCacheKeysLeastToMostRecent: [String] = []
    private var originCacheKeysLeastToMostRecent: [String] = []
    private var inFlightByIconCacheKey: [String: InFlightResolution] = [:]

    init(
        maxIconCacheEntries: Int = browserFaviconStoreDefaultMaxIconCacheEntries,
        maxOriginCacheEntries: Int = browserFaviconStoreDefaultMaxOriginCacheEntries
    ) {
        self.maxIconCacheEntries = max(1, maxIconCacheEntries)
        self.maxOriginCacheEntries = max(1, maxOriginCacheEntries)
    }

    func cachedIcon(forPageURL pageURL: URL, cachePartition: String) -> (request: BrowserFaviconRequest, pngData: Data)? {
        guard let pageOrigin = BrowserFaviconRequest.pageOrigin(for: pageURL) else { return nil }
        let originLookupRequest = BrowserFaviconRequest(
            pageOrigin: pageOrigin,
            iconURLString: "",
            cachePartition: cachePartition
        )
        guard let iconURLString = iconURLStringByOriginCacheKey[originLookupRequest.originCacheKey] else {
            return nil
        }
        touchOriginCacheKey(originLookupRequest.originCacheKey)
        let request = BrowserFaviconRequest(
            pageOrigin: pageOrigin,
            iconURLString: iconURLString,
            cachePartition: cachePartition
        )
        guard let pngData = pngDataByIconCacheKey[request.iconCacheKey] else { return nil }
        touchIconCacheKey(request.iconCacheKey)
        return (request, pngData)
    }

    func cachedIcon(for request: BrowserFaviconRequest) -> Data? {
        guard let pngData = pngDataByIconCacheKey[request.iconCacheKey] else { return nil }
        touchIconCacheKey(request.iconCacheKey)
        return pngData
    }

    func resolve(
        _ request: BrowserFaviconRequest,
        fetch: @escaping Fetch
    ) async -> Data? {
        if let pngData = cachedIcon(for: request) {
            return pngData
        }

        let resolution: InFlightResolution
        if let existing = inFlightByIconCacheKey[request.iconCacheKey] {
            resolution = existing
        } else {
            let id = UUID()
            let task = Task.detached(priority: .utility) {
                await fetch()
            }
            resolution = InFlightResolution(id: id, task: task)
            inFlightByIconCacheKey[request.iconCacheKey] = resolution
        }

        let pngData = await resolution.task.value
        if inFlightByIconCacheKey[request.iconCacheKey]?.id == resolution.id {
            inFlightByIconCacheKey[request.iconCacheKey] = nil
        }
        guard let pngData else {
            return cachedIcon(for: request)
        }
        remember(pngData, for: request)
        return pngData
    }

    private func remember(_ pngData: Data, for request: BrowserFaviconRequest) {
        pngDataByIconCacheKey[request.iconCacheKey] = pngData
        iconURLStringByOriginCacheKey[request.originCacheKey] = request.iconURLString
        touchIconCacheKey(request.iconCacheKey)
        touchOriginCacheKey(request.originCacheKey)
        trimIconCacheIfNeeded()
        trimOriginCacheIfNeeded()
    }

    private func touchIconCacheKey(_ key: String) {
        iconCacheKeysLeastToMostRecent.removeAll { $0 == key }
        iconCacheKeysLeastToMostRecent.append(key)
    }

    private func touchOriginCacheKey(_ key: String) {
        originCacheKeysLeastToMostRecent.removeAll { $0 == key }
        originCacheKeysLeastToMostRecent.append(key)
    }

    private func trimIconCacheIfNeeded() {
        while iconCacheKeysLeastToMostRecent.count > maxIconCacheEntries {
            let evictedKey = iconCacheKeysLeastToMostRecent.removeFirst()
            pngDataByIconCacheKey[evictedKey] = nil
        }
    }

    private func trimOriginCacheIfNeeded() {
        while originCacheKeysLeastToMostRecent.count > maxOriginCacheEntries {
            let evictedKey = originCacheKeysLeastToMostRecent.removeFirst()
            iconURLStringByOriginCacheKey[evictedKey] = nil
        }
    }
}
