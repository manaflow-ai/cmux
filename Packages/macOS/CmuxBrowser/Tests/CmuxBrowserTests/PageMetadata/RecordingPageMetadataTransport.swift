@testable import CmuxBrowser

actor RecordingPageMetadataTransport: BrowserPageMetadataTransporting {
    private var responses: [BrowserPageMetadataHTTPResponse]
    private var hosts: [String] = []
    private var addresses: [BrowserPageMetadataResolvedAddress] = []

    init(responses: [BrowserPageMetadataHTTPResponse]) {
        self.responses = responses
    }

    func response(
        for request: BrowserPageMetadataRequest,
        address: BrowserPageMetadataResolvedAddress,
        maximumBodyBytes: Int
    ) async -> BrowserPageMetadataHTTPResponse? {
        _ = maximumBodyBytes
        hosts.append(request.host)
        addresses.append(address)
        return responses.isEmpty ? nil : responses.removeFirst()
    }

    func recordedHosts() -> [String] {
        hosts
    }

    func recordedAddresses() -> [BrowserPageMetadataResolvedAddress] {
        addresses
    }
}
