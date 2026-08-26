import CmuxFoundation
import Foundation

/// A validated HTTP request whose DNS result will be supplied separately.
struct BrowserPageMetadataRequest: Sendable {
    let url: URL
    let scheme: String
    let host: String
    let port: UInt16
    let bytes: Data

    init?(url: URL, addressPolicy: NetworkAddressPolicy) {
        guard url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: false) else {
            return nil
        }
        let host = addressPolicy.normalizedHost(rawHost)
        guard addressPolicy.allowsPublicInternetHost(host),
              host.utf8.allSatisfy({ $0 >= 0x21 && $0 != 0x7F }) else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let resolvedPort = url.port ?? defaultPort
        guard resolvedPort > 0, let port = UInt16(exactly: resolvedPort) else { return nil }

        let hostValue = host.contains(":") ? "[\(host)]" : host
        let hostHeader = resolvedPort == defaultPort ? hostValue : "\(hostValue):\(resolvedPort)"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var pathAndQuery = components?.percentEncodedPath ?? ""
        if pathAndQuery.isEmpty { pathAndQuery = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            pathAndQuery += "?\(query)"
        }
        let request = [
            "GET \(pathAndQuery) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
            "Accept-Encoding: identity",
            "Range: bytes=0-65535",
            "User-Agent: cmux-links-title-fetcher",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        guard let bytes = request.data(using: .utf8) else { return nil }

        self.url = url
        self.scheme = scheme
        self.host = host
        self.port = port
        self.bytes = bytes
    }
}
