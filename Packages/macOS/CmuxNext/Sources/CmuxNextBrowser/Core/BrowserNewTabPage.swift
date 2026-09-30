public import Foundation

/// The New Tab page (Chrome parity). A new Chromium tab opens
/// `chrome://newtab/`: an extension that overrides the New Tab page
/// (Momentum, Infinity) shows there; without one the fork loads
/// `CEFNewTabPage.fallbackURL`, a blank page in the Ghostty theme background
/// (`PageBackground`), never Google's New Tab page. The address of either
/// stays `chrome://newtab/` (the shim reports the entry's virtual URL), and
/// the omnibar shows it as empty, as Chrome does. WebKit tabs open
/// `about:blank`.
public nonisolated enum BrowserNewTabPage {
    public static let chromiumURL = "chrome://newtab/"
    public static let blankURL = "about:blank"

    /// What a new tab of `engine` loads when the user gave no URL.
    public static func initialURL(for engine: BrowserEngineKind) -> String {
        engine == .cef ? chromiumURL : blankURL
    }

    /// True for the New Tab page and the blank page: the omnibar shows
    /// nothing, the title falls back to "New Tab", history skips it.
    public static func isNewTabPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isNewTabPage(url.absoluteString)
    }

    public static func isNewTabPage(_ text: String) -> Bool {
        switch text.lowercased() {
        case blankURL, chromiumURL, "chrome://newtab": true
        default: false
        }
    }
}
