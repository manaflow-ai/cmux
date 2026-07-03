import Foundation
import WebKit

struct BrowserWebAuthnSecurityOrigin {
    let scheme: String
    let host: String
    let port: Int

    init(origin: WKSecurityOrigin) {
        scheme = origin.protocol.lowercased()
        host = Self.normalizedHost(origin.host)
        port = Self.normalizedPort(scheme: scheme, port: origin.port)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            return nil
        }

        self.scheme = scheme
        self.host = Self.normalizedHost(host)
        port = Self.normalizedPort(scheme: scheme, port: url.port)
    }

    var serializedString: String {
        let isDefaultHTTPS = scheme == "https" && port == 443
        let isDefaultHTTP = scheme == "http" && port == 80
        let host = Self.serializedHost(host)
        if isDefaultHTTPS || isDefaultHTTP || port < 0 {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    func matches(_ origin: WKSecurityOrigin) -> Bool {
        let other = Self(origin: origin)
        return scheme == other.scheme && host == other.host && port == other.port
    }

    func permits(relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        if host == normalizedIdentifier {
            return true
        }
        return host.hasSuffix(".\(normalizedIdentifier)") &&
            Self.nativeParentRelyingPartyIdentifiers.contains(normalizedIdentifier)
    }

    func isWithinRelyingPartyScope(_ relyingPartyIdentifier: String) -> Bool {
        let normalizedIdentifier = relyingPartyIdentifier.lowercased()
        guard !normalizedIdentifier.isEmpty else { return false }
        return host == normalizedIdentifier || host.hasSuffix(".\(normalizedIdentifier)")
    }

    var isPotentiallyTrustworthyWebAuthnOrigin: Bool {
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
