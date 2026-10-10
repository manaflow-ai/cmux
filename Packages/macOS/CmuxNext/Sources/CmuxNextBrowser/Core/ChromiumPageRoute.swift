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
    /// Chromium's own page, in a Chromium tab.
    case chromium(URL)

    /// Hosts whose pages cmux shows itself, and the cmux page for each.
    static let cmuxPages: [String: String] = [
        "history": "cmux://history",
        "bookmarks": "cmux://bookmarks",
    ]

    /// The route of `url`, nil when it is not a `chrome://` page. Any
    /// spelling works: `CHROME://History`, `about:history` and
    /// `chrome://history` route alike (`ChromiumInternalURL`).
    public init?(_ url: URL) {
        guard let page = ChromiumInternalURL(typed: url.absoluteString), page.url.scheme == "chrome",
              let host = page.url.host() else { return nil }
        if let address = Self.cmuxPages[host], let cmuxURL = URL(string: address) {
            self = .cmuxPage(cmuxURL)
        } else if host == "settings", page.url.path() == "/" {
            self = .browserSettings
        } else {
            self = .chromium(page.url)
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
