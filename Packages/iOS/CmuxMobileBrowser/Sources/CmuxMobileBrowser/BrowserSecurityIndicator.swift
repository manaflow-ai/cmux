public import Foundation

/// The address-bar security indicator for a browser URL.
public enum BrowserSecurityIndicator: Equatable, Sendable {
    /// An HTTPS page.
    case secure
    /// A public HTTP page.
    case insecure
    /// No indicator should be shown.
    case none

    /// Classify the security indicator for a URL.
    ///
    /// - Parameter url: The committed browser URL, or `nil` before navigation.
    public init(url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased() else {
            self = .none
            return
        }
        if scheme == "https" {
            self = .secure
            return
        }
        guard scheme == "http",
              let host = url.host(percentEncoded: false),
              !Self.isLocalOrPrivateHost(host)
        else {
            self = .none
            return
        }
        self = .insecure
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
