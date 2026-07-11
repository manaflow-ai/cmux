internal import CMUXMobileCore
internal import Foundation

// Route selection for reconnect/attach: which published route a phone should
// dial for a Mac, and why loopback routes are only valid on the simulator.
// Extracted from MobileShellComposite.swift (Swift file length budget).
extension MobileShellComposite {
    /// Whether route selection should avoid loopback routes. A loopback route
    /// (`.debugLoopback`, `127.0.0.1`) names the host it runs on, so on a
    /// physical device it can only ever reach the phone itself, never a remote
    /// Mac. On the simulator `127.0.0.1` IS the host Mac, so loopback is valid
    /// (and is how the dev/UI-test mock host attaches).
    static var prefersNonLoopbackRoutes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// Whether `host` is a numeric IP literal (IPv4 or IPv6) rather than a name
    /// that needs DNS resolution. Used to prefer directly-dialable IP routes over
    /// MagicDNS hostnames, which fail to resolve on some clients.
    static func isIPLiteralHost(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 literal
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else { return false }
            return String(value) == part // reject leading zeros / non-canonical
        }
    }
}
