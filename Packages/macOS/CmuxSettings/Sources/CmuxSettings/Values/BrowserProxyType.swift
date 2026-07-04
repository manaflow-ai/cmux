import Foundation

/// The protocol an embedded-browser proxy speaks.
///
/// Mirrors the two forward-proxy flavors `Network.framework`'s
/// `ProxyConfiguration` can express for a `WKWebsiteDataStore`: SOCKSv5 and
/// HTTP CONNECT. ``off`` means cmux applies no proxy of its own.
public enum BrowserProxyType: String, CaseIterable, Sendable, Equatable, SettingCodable {
    /// No cmux-managed browser proxy.
    ///
    /// Local panes still mirror an active macOS system proxy for the loopback fix
    /// when no user proxy is configured.
    case off
    /// A SOCKSv5 proxy (`ProxyConfiguration(socksv5Proxy:)`).
    case socks5
    /// An HTTP CONNECT proxy (`ProxyConfiguration(httpCONNECTProxy:)`).
    case httpConnect

    /// Resolves a loosely typed string to a known type, defaulting to ``off``.
    ///
    /// Unknown or misspelled values resolve to ``off`` so a typo never crashes
    /// config loading or silently routes traffic somewhere unexpected. Accepts
    /// common aliases and URL schemes so both the cmux.json `type` field and the
    /// `CMUX_BROWSER_PROXY` URL scheme map onto the same set.
    ///
    /// - Parameter raw: The string value from config or an environment URL
    ///   scheme.
    public init(lenient raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "socks5", "socks", "socksv5", "socks-5", "socks_5":
            self = .socks5
        case "httpconnect", "http-connect", "http_connect", "connect", "http", "https":
            self = .httpConnect
        default:
            self = .off
        }
    }
}
