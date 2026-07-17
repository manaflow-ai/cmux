internal import CMUXMobileCore
internal import Foundation
internal import CmuxMobileSupport

// Route selection for reconnect/attach: which published route a phone should
// dial for a Mac, and why loopback routes are only valid on the simulator.
// Extracted from MobileShellComposite.swift (Swift file length budget).
extension MobileShellComposite {
    /// Whether stored-route selection must reject loopback routes. A loopback route
    /// (`.debugLoopback`, `127.0.0.1`) names the host it runs on, so on a
    /// physical device it can only ever reach the phone itself, never a remote
    /// Mac. Simulators and explicit mock-data UI tests host their test server at
    /// loopback, so those harnesses opt into it instead of weakening real-device
    /// reconnect for every debug build.
    static var prefersNonLoopbackRoutes: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        !UITestConfig.mockDataEnabled
        #else
        false
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
