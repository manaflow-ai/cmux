public import Foundation

/// Where a typed Chromium internal page opens in cmux.
///
/// cmux Next routes `chrome://history`, `chrome://bookmarks` and the password
/// manager to cmux's own pages. cmux has no such pages, so only
/// `chrome://settings` (the root) is routed: it opens Settings > Browser,
/// the one place cmux keeps browser preferences. Every other page, including
/// the settings sections (`chrome://settings/content`), is Chromium's own
/// page in a Chromium panel.
///
/// Reference: cmux Next `CmuxNextBrowser/Core/ChromiumPageRoute.swift` and the
/// `new-tab-chrome-pages` release note.
public enum ChromiumPageRoute: Equatable, Sendable {
    /// Settings, Browser section.
    case browserSettings
    /// Chromium's own page, in a Chromium panel.
    case chromium(URL)

    /// The route of `url`, nil when it is not a Chromium internal page. Any
    /// spelling works: `CHROME://Settings` and `about:settings` route alike.
    public init?(_ url: URL) {
        guard let page = ChromiumInternalURL(typed: url.absoluteString) else { return nil }
        if page.url.scheme == "chrome", page.url.host() == "settings", page.url.path() == "/" {
            self = .browserSettings
        } else {
            self = .chromium(page.url)
        }
    }

    /// The route of typed text, nil when the text does not name a Chromium
    /// internal page.
    public init?(typed text: String) {
        guard let page = ChromiumInternalURL(typed: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.init(page.url)
    }

    /// Pages the address bar completes after `chrome://` (or `about:`), in
    /// the order they are offered.
    public static let completedHosts: [String] = [
        "extensions", "history", "bookmarks", "downloads", "settings", "version", "flags", "gpu",
        "inspect", "net-internals", "process-internals", "about", "policy", "crashes", "components",
        "media-internals",
    ]

    /// The completion URLs for typed `chrome://ex`, `chrome:ex` or `about:ex`,
    /// in `completedHosts` order. Empty for any other text, for a name that
    /// already has a path, and when `allowsChromiumSchemes` is false (a WebKit
    /// panel cannot show these pages).
    public static func completions(for text: String, allowsChromiumSchemes: Bool) -> [URL] {
        guard allowsChromiumSchemes, let typedName = typedName(text) else { return [] }
        return completedHosts
            .filter { $0.hasPrefix(typedName) }
            .compactMap { URL(string: "chrome://\($0)/") }
    }

    /// The page name typed so far after `chrome:` (slashes optional) or
    /// `about:`, lowercased; nil for other text or a name with a path.
    static func typedName(_ text: String) -> String? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        let rest: Substring
        if lowered.hasPrefix("chrome:") {
            rest = lowered.dropFirst("chrome:".count).drop { $0 == "/" }
        } else if lowered.hasPrefix("about:") {
            rest = lowered.dropFirst("about:".count)
        } else {
            return nil
        }
        guard !rest.contains(where: { "/?#".contains($0) }) else { return nil }
        return String(rest)
    }

    /// Whether typed omnibar text must stay on this device: a Chromium
    /// internal address is never sent to the search engine for suggestions.
    public static func isPrivateTypedText(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("chrome:") || lowered.hasPrefix("chrome-extension:")
            || (lowered.hasPrefix("about:") && ChromiumInternalURL(typed: lowered) != nil)
    }
}
