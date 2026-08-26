protocol BrowserPageMetadataTransporting: Sendable {
    func response(
        for request: BrowserPageMetadataRequest,
        address: BrowserPageMetadataResolvedAddress,
        maximumBodyBytes: Int
    ) async -> BrowserPageMetadataHTTPResponse?
}
