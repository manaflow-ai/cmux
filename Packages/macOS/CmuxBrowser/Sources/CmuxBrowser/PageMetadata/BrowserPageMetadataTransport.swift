/// Dials validated numeric endpoints without performing another DNS lookup.
struct BrowserPageMetadataTransport: BrowserPageMetadataTransporting, Sendable {
    func response(
        for request: BrowserPageMetadataRequest,
        address: BrowserPageMetadataResolvedAddress,
        maximumBodyBytes: Int
    ) async -> BrowserPageMetadataHTTPResponse? {
        guard let endpointHost = address.endpointHost else { return nil }
        let connection = BrowserPinnedHTTPConnection(
            request: request,
            endpointHost: endpointHost,
            maximumWireBytes: maximumBodyBytes + 128 * 1024
        )
        guard let wireData = await connection.fetch() else { return nil }
        return BrowserPageMetadataHTTPResponse(
            wireData: wireData,
            maximumBodyBytes: maximumBodyBytes
        )
    }
}
