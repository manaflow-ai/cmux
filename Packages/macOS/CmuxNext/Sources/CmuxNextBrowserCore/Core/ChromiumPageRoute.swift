import CCmuxURLInputFFI
public import Foundation

/// Where a Chromium internal page opens (spec decision CHROME-INTERNAL-PAGES):
/// cmux's own page when cmux has a page for the same data, so there is one
/// source of data; else Chromium's own WebUI in a Chromium tab.
///
/// - `chrome://history` (any path) is cmux's History page, `cmux://history`.
/// - `chrome://bookmarks` (any path) is cmux's Bookmarks page, `cmux://bookmarks`.
/// - `chrome://settings` (the root only) is Settings > Browser. Its sections
///   (`chrome://settings/content`, `/cookies`, ...) stay Chromium pages,
///   because cmux does not cover them.
/// - `chrome://password-manager` (any path) and `chrome://settings/passwords`
///   are cmux's Passwords page (decision P4): Chromium's own page exports
///   passwords past `browser.passwords.allowExport`.
/// - Every other `chrome://` page (extensions, version, flags, downloads, ...)
///   is Chromium's own page.
///
/// The inventory of pages and the reason for each row:
/// .cmux-scratch/hq-ff/cx-ldj-webui-inventory.md (hq).
public nonisolated enum ChromiumPageRoute: Equatable, Sendable {
    /// cmux's own page for the same data, shown in a browser tab.
    case cmuxPage(URL)
    /// Settings, Browser section.
    case browserSettings
    /// cmux's Passwords page tab.
    case passwordsPage
    /// Chromium's own page, in a Chromium tab.
    case chromium(URL)

    /// The route of `url`, nil when it is not a `chrome://` page. Any
    /// spelling works: `CHROME://History`, `about:history` and
    /// `chrome://history` route alike. The table is Rust's (cmux-url-input
    /// src/chromium.rs, over URLInputFFI).
    public init?(_ url: URL) {
        let route = URLInputFFI.chromiumPageRoute(url.absoluteString)
        switch route.kind {
        case CMUX_URL_INPUT_ROUTE_CMUX_PAGE:
            guard let page = route.url.flatMap(URL.init(string:)) else { return nil }
            self = .cmuxPage(page)
        case CMUX_URL_INPUT_ROUTE_BROWSER_SETTINGS:
            self = .browserSettings
        case CMUX_URL_INPUT_ROUTE_PASSWORDS_PAGE:
            self = .passwordsPage
        case CMUX_URL_INPUT_ROUTE_CHROMIUM:
            guard let page = route.url.flatMap(URL.init(string:)) else { return nil }
            self = .chromium(page)
        default:
            return nil
        }
    }

    /// The route of typed text (`chrome://history`, `about:settings`), nil
    /// when the text does not name a `chrome://` page.
    public init?(typed text: String) {
        guard let page = ChromiumInternalURL(typed: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(page.url)
    }

    /// True when cmux shows the page itself, so a WebKit tab can open it too.
    public var isCmuxOwned: Bool {
        if case .chromium = self { return false }
        return true
    }

    /// Pages the omnibar completes after `chrome://` (or `about:`): the
    /// common pages of the spec decision. A WebKit tab completes only the
    /// pages cmux shows itself.
    public static let completedHosts: [String] = [
        "extensions", "history", "bookmarks", "downloads", "settings", "version", "flags", "gpu",
        "inspect", "net-internals", "process-internals", "about", "password-manager", "policy",
        "crashes", "components", "media-internals",
    ]
}
