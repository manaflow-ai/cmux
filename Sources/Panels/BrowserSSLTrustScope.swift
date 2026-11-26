import Foundation

struct BrowserSSLTrustScope: Hashable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? 443
    }

    init?(protectionSpace: URLProtectionSpace) {
        let rawScheme = protectionSpace.protocol?.lowercased() ?? "https"
        guard rawScheme == "https",
              let host = BrowserInsecureHTTPSettings.normalizeHost(protectionSpace.host) else {
            return nil
        }
        scheme = rawScheme
        self.host = host
        port = protectionSpace.port > 0 ? protectionSpace.port : 443
    }
}
