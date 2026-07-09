public import Foundation
import Darwin
import Network

/// SSRF-resistant safety policy for fetching remote markdown images over a
/// custom proxy URL scheme.
///
/// An instance is configured with the custom URL scheme its renderer proxies
/// remote images through (e.g. `cmux-remote-image`); ``remoteImageURL(from:)``
/// unwraps a request in that scheme back to the underlying HTTPS URL only when
/// it passes the safety checks. The remaining members are pure predicates and
/// builders that enforce HTTPS-only, no embedded credentials, port 443, and an
/// IPv4/IPv6 allowlist that rejects loopback, link-local, private, CGNAT,
/// multicast, and other non-routable ranges (resolving the host where required
/// so DNS cannot point a public name at a private address).
public struct MarkdownRemoteImageSecurity: Sendable {
    /// The maximum number of image bytes a single remote fetch may return.
    public static let maximumRemoteImageBytes = 8 * 1024 * 1024

    /// The custom URL scheme remote-image requests arrive on; injected so this
    /// policy carries no reference to the app-side scheme handler.
    public let remoteImageURLScheme: String

    /// Creates a policy that recognizes requests in `remoteImageURLScheme`.
    public init(remoteImageURLScheme: String) {
        self.remoteImageURLScheme = remoteImageURLScheme
    }

    /// Extracts the underlying HTTPS image URL from a proxy-scheme `requestURL`,
    /// or `nil` if the scheme, encoding, or target URL is unsafe.
    public func remoteImageURL(from requestURL: URL) -> URL? {
        guard requestURL.scheme?.lowercased() == remoteImageURLScheme,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawRemoteURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remoteURL = URL(string: rawRemoteURL),
              isPotentiallySafeRemoteImageURL(remoteURL) else {
            return nil
        }
        return remoteURL
    }

    /// Whether `url` passes every static safety check without resolving DNS.
    public func isPotentiallySafeRemoteImageURL(_ url: URL) -> Bool {
        isSafeRemoteImageURL(url, resolveHost: false)
    }

    /// Whether `url` is a safe HTTPS image target, optionally requiring that the
    /// host resolves only to allowed addresses.
    public func isSafeRemoteImageURL(_ url: URL, resolveHost: Bool = true) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false),
              isAllowedHostNameOrLiteral(host) else {
            return false
        }
        return !resolveHost || hostResolvesOnlyToAllowedAddresses(host)
    }

    /// Resolves `url` into one pinned fetch target per allowed resolved address,
    /// or an empty array when the URL is unsafe or resolves to no allowed address.
    public func pinnedFetchTargets(for url: URL) -> [MarkdownRemoteImageFetchTarget] {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false),
              let endpoints = resolvedAllowedEndpoints(for: host),
              !endpoints.isEmpty else {
            return []
        }
        return endpoints.map {
            MarkdownRemoteImageFetchTarget(url: url, serverName: host, endpointHost: $0, port: 443)
        }
    }

    /// The percent-encoded path-and-query string for `url`'s HTTP request line.
    func pathAndQuery(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var value = components?.percentEncodedPath.isEmpty == false ? components?.percentEncodedPath ?? "/" : "/"
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    /// Builds the raw HTTP/1.1 GET request bytes for `url` against `host`, or
    /// `nil` if the host cannot form a safe `Host` header value.
    public func requestBytes(for url: URL, host: String) -> Data? {
        guard let hostHeader = httpHostHeaderValue(for: host) else { return nil }
        let request = [
            "GET \(pathAndQuery(for: url)) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: image/png,image/jpeg,image/gif,image/webp,image/avif;q=0.9,image/svg+xml;q=0.9,*/*;q=0.1",
            "User-Agent: cmux-markdown-image-loader",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return request.data(using: .utf8)
    }

    /// The normalized host a remote image fetch would target, used as the consent
    /// key, or `nil` if `url` is unsafe.
    public func remoteImageConsentHost(for url: URL) -> String? {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        let normalized = normalizedRemoteImageHost(host)
        return normalized.isEmpty ? nil : normalized
    }

    /// Canonicalizes a `Content-Type` value to a supported `image/*` type, or
    /// `nil` if the type is unrecognized.
    public func canonicalImageMIMEType(_ raw: String?) -> String? {
        let mimeType = String(raw ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch mimeType {
        case "image/png":
            return "image/png"
        case "image/jpeg", "image/jpg":
            return "image/jpeg"
        case "image/gif":
            return "image/gif"
        case "image/webp":
            return "image/webp"
        case "image/avif":
            return "image/avif"
        case "image/svg+xml":
            return "image/svg+xml"
        default:
            return nil
        }
    }

    private func normalizedRemoteImageHost(_ rawHost: String) -> String {
        rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func isAllowedHostNameOrLiteral(_ rawHost: String) -> Bool {
        let host = normalizedRemoteImageHost(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host == "local" || host.hasSuffix(".local") { return false }
        if let bytes = ipv4Bytes(host) {
            return isAllowedIPv4Address(bytes)
        }
        if let bytes = ipv6Bytes(host) {
            return isAllowedIPv6Address(bytes)
        }
        return true
    }

    private func hostResolvesOnlyToAllowedAddresses(_ rawHost: String) -> Bool {
        guard let endpoints = resolvedAllowedEndpoints(for: rawHost) else { return false }
        return !endpoints.isEmpty
    }

    private func resolvedAllowedEndpoints(for rawHost: String) -> [NWEndpoint.Host]? {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let bytes = ipv4Bytes(host) {
            guard isAllowedIPv4Address(bytes),
                  let endpoint = ipv4Endpoint(bytes) else { return nil }
            return [endpoint]
        }
        if let bytes = ipv6Bytes(host) {
            guard isAllowedIPv6Address(bytes),
                  let endpoint = ipv6Endpoint(bytes) else { return nil }
            return [endpoint]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var endpoints: [NWEndpoint.Host] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }
            switch current.pointee.ai_family {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
                }
                guard isAllowedIPv4Address(bytes),
                      let endpoint = ipv4Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                guard isAllowedIPv6Address(bytes),
                      let endpoint = ipv6Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            default:
                continue
            }
        }
        var seen = Set<String>()
        return endpoints.filter { seen.insert(String(describing: $0)).inserted }
    }

    private func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address.s_addr) { $0 })
    }

    private func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address) { $0 })
    }

    private func isAllowedIPv4Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 { return false }
        if first == 10 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 127 { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (18...19).contains(second) { return false }
        if first >= 224 { return false }
        return true
    }

    private func isAllowedIPv6Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isAllowedIPv4Address(Array(bytes[12..<16]))
        }
        return true
    }

    private func ipv4Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.map(String.init).joined(separator: ".")
        guard let address = IPv4Address(value) else { return nil }
        return .ipv4(address)
    }

    private func ipv6Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            for index in bytes.indices {
                buffer[index] = bytes[index]
            }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            guard inet_ntop(AF_INET6, pointer, &output, socklen_t(output.count)) != nil else {
                return nil
            }
            let value = String(
                decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard let networkAddress = IPv6Address(value) else { return nil }
            return .ipv6(networkAddress)
        }
    }

    private func isSafeHTTPHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte >= 0x21 && byte != 0x7f
        }
    }

    private func httpHostHeaderValue(for rawHost: String) -> String? {
        let host = normalizedRemoteImageHost(rawHost)
        guard isSafeHTTPHeaderValue(host) else { return nil }
        if ipv6Bytes(host) != nil {
            return "[\(host)]"
        }
        return host
    }
}
