import Foundation

actor BrowserFaviconStore {
    typealias Fetch = @MainActor @Sendable () async -> Data?

    private struct InFlightResolution {
        let id: UUID
        let task: Task<Data?, Never>
    }

    private var pngDataByIconCacheKey: [String: Data] = [:]
    private var iconURLStringByOriginCacheKey: [String: String] = [:]
    private var inFlightByIconCacheKey: [String: InFlightResolution] = [:]

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
        let request = BrowserFaviconRequest(
            pageOrigin: pageOrigin,
            iconURLString: iconURLString,
            cachePartition: cachePartition
        )
        guard let pngData = pngDataByIconCacheKey[request.iconCacheKey] else { return nil }
        return (request, pngData)
    }

    func cachedIcon(for request: BrowserFaviconRequest) -> Data? {
        pngDataByIconCacheKey[request.iconCacheKey]
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
            let task = Task { @MainActor in
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
    }
}
