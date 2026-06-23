/// The forced Safari user-agent string applied to browser web views and requests.
///
/// Some WebKit builds return a minimal UA without `Version`/`Safari` tokens, and
/// some installs carry legacy Chrome UA overrides. Both can cause Google to serve
/// fallback or old UIs, or trigger bot checks. Forcing a known-good Safari UA on
/// every web view and outgoing request avoids that. This is a pure constant with
/// no stored state and no dependencies.
public struct BrowserUserAgent: Sendable {
    /// The forced Safari user-agent string.
    public static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"

    private init() {}
}
