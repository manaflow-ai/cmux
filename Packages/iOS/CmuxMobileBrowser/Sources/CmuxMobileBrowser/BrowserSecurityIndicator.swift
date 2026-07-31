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

    // These helpers are static members rather than file-scope functions
    // because scripts/lint-ios-package-conventions.sh forbids top-level
    // funcs in iOS packages; the enum has cases, so it is a real value
    // type, not a static namespace.
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
        // IPv4 link-local.
        if values[0] == 169 && values[1] == 254 { return true }
        // CGNAT 100.64.0.0/10 — Tailscale addresses live here, and Tailscale
        // is the primary way cmux devices reach each other.
        if values[0] == 100 && (64...127).contains(values[1]) { return true }
        return false
    }

    private static func isPrivateOrLoopbackIPv6(_ host: String) -> Bool {
        // Only IPv6 literals contain ":" (the port is not part of `URL.host`).
        // Ordinary DNS names must never match the ULA/link-local prefixes;
        // e.g. fda.gov is a public host and keeps its HTTP warning.
        guard host.contains(":") else { return false }
        // IPv4-mapped IPv6 (`::ffff:127.0.0.1`) classifies by its embedded
        // IPv4 address.
        if host.hasPrefix("::ffff:") {
            return isPrivateOrLoopbackIPv4(String(host.dropFirst("::ffff:".count)))
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        return host.hasPrefix("fe80:")
    }
}
