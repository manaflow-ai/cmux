import Foundation

public extension String {
    /// Desktop Safari user-agent string the cmux browser forces on its web
    /// views and suggestion requests.
    ///
    /// Some WebKit builds return a minimal UA without `Version`/`Safari`
    /// tokens, and some installs may carry legacy Chrome UA overrides. Both can
    /// cause Google to serve fallback/old UIs or trigger bot checks, so cmux
    /// pins this Safari UA everywhere it speaks to remote services.
    static let safariDesktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15"
}
