public import Foundation
public import WebKit

/// A normalized web origin (scheme, host, default-aware port) used to serialize
/// the WebAuthn client data origin and to gate relying-party identifiers.
public struct BrowserWebAuthnSecurityOrigin {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(origin: WKSecurityOrigin) {
        scheme = origin.protocol.lowercased()
        host = origin.host.lowercased()
        port = Self.normalizedPort(scheme: scheme, port: origin.port)
    }

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }

        self.scheme = scheme
        self.host = host
        port = Self.normalizedPort(scheme: scheme, port: url.port)
    }

    /// The origin serialized for WebAuthn client data (default ports omitted).
    public var serializedString: String {
        let isDefaultHTTPS = scheme == "https" && port == 443
        let isDefaultHTTP = scheme == "http" && port == 80
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

    /// Whether this origin's host may act for the given relying-party identifier.
    public func permits(relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        return host == normalizedIdentifier || host.hasSuffix(".\(normalizedIdentifier)")
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
}
