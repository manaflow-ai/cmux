public import Foundation

/// Computes the address-bar security indicator for a browser URL.
public struct BrowserSecurityIndicator {
    /// The visual security state shown next to the address.
    public enum State: Equatable, Sendable {
        /// An HTTPS page.
        case secure
        /// A public HTTP page.
        case insecure
        /// No indicator should be shown.
        case none
    }

    private init() {}

    /// Return the security indicator state for a URL.
    ///
    /// - Parameter url: The committed browser URL, or `nil` before navigation.
    /// - Returns: The indicator state for the address bar.
    public static func state(for url: URL?) -> State {
        guard let url, let scheme = url.scheme?.lowercased() else { return .none }
        if scheme == "https" { return .secure }
        guard scheme == "http" else { return .none }
        guard let host = url.host(percentEncoded: false), !isLocalOrPrivateHost(host) else {
            return .none
        }
        return .insecure
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }
        if isPrivateOrLoopbackIPv4(normalized) {
            return true
        }
        return isPrivateOrLoopbackIPv6(normalized)
    }

    private static func isPrivateOrLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        if values[0] == 127 { return true }
        if values[0] == 10 { return true }
        if values[0] == 192 && values[1] == 168 { return true }
        if values[0] == 172 && (16...31).contains(values[1]) { return true }
        return false
    }

    private static func isPrivateOrLoopbackIPv6(_ host: String) -> Bool {
        if host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        return host.hasPrefix("fe80:")
    }
}
