@testable import CmuxBrowser

struct StubPageMetadataResolver: BrowserPageMetadataResolving {
    let addressesByHost: [String: [BrowserPageMetadataResolvedAddress]]

    func addresses(for host: String) async -> [BrowserPageMetadataResolvedAddress] {
        addressesByHost[host] ?? []
    }
}
