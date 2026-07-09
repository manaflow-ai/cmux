public import Foundation
public import WebKit

/// A normalized web origin (scheme, host, default-aware port) used to serialize
/// the WebAuthn client data origin and to gate relying-party identifiers.
public struct BrowserWebAuthnSecurityOrigin {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(origin: WKSecurityOrigin) {
        // WKSecurityOrigin is @MainActor under Swift 6.1 (WebKit); these reads
        // happen on WebKit's main-thread delegate callbacks, so assumeIsolated is
        // behavior-preserving. (Local Swift 6.3 accepted the bare reads.)
        let (originProtocol, originHost, originPort) = MainActor.assumeIsolated {
            (origin.protocol, origin.host, origin.port)
        }
        scheme = originProtocol.lowercased()
        host = Self.normalizedHost(originHost)
        port = Self.normalizedPort(scheme: scheme, port: originPort)
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            return nil
        }

        self.scheme = scheme
        self.host = Self.normalizedHost(host)
        port = Self.normalizedPort(scheme: scheme, port: url.port)
    }

    /// The origin serialized for WebAuthn client data (default ports omitted).
    public var serializedString: String {
        let isDefaultHTTPS = scheme == "https" && port == 443
        let isDefaultHTTP = scheme == "http" && port == 80
        let host = Self.serializedHost(host)
        if isDefaultHTTPS || isDefaultHTTP || port < 0 {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    /// Whether this origin equals the normalized form of `origin`.
    public func matches(_ origin: WKSecurityOrigin) -> Bool {
        let other = Self(origin: origin)
        return scheme == other.scheme && host == other.host && port == other.port
    }

    /// Whether native AuthenticationServices should handle the relying-party identifier for this origin.
    public func permits(relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        if host == normalizedIdentifier {
            return true
        }
        return host.hasSuffix(".\(normalizedIdentifier)") &&
            Self.nativeParentRelyingPartyIdentifiers.contains(normalizedIdentifier)
    }

    /// Whether this origin is in the WebAuthn relying-party scope for `relyingPartyIdentifier`.
    public func isWithinRelyingPartyScope(_ relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        return host == normalizedIdentifier || host.hasSuffix(".\(normalizedIdentifier)")
    }

    /// Whether this origin is secure enough for a WebAuthn ceremony.
    public var isPotentiallyTrustworthyWebAuthnOrigin: Bool {
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        return host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host == "::1" ||
            isIPv4LoopbackHost
    }

    private var isIPv4LoopbackHost: Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else {
            return false
        }
        return octets.dropFirst().allSatisfy { octet in
            guard let value = Int(octet) else {
                return false
            }
            return (0...255).contains(value)
        }
    }

    private static func normalizedPort(scheme: String, port: Int?) -> Int {
        if let port, port > 0 {
            return port
        }

        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowercased = host.lowercased()
        if lowercased.hasPrefix("[") && lowercased.hasSuffix("]") {
            return String(lowercased.dropFirst().dropLast())
        }
        return lowercased
    }

    private static func serializedHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    // Without a bundled public-suffix list, keep native parent RP IDs explicit.
    private static let nativeParentRelyingPartyIdentifiers: Set<String> = [
        "google.com",
    ]
}
