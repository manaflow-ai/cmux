public import Foundation

/// Omnibar rows for Chromium internal page names (spec decision
/// CHROME-INTERNAL-PAGES, "Omnibar completes chrome:// names"): typed
/// `chrome://ex`, `chrome:ex` or `about:ex` offers `chrome://extensions`.
/// A Chromium tab completes every page of `ChromiumPageRoute.completedHosts`;
/// a WebKit tab only the pages cmux shows itself (History, Bookmarks,
/// Settings). Pure.
public nonisolated struct OmniboxInternalPages {
    public init() {}

    /// Above history and bookmark rows: the person typed the scheme.
    static let score: Double = 900

    /// The rows for `text`, in `completedHosts` order; empty when the text
    /// does not start with `chrome:` or `about:`.
    public static func rows(for text: String, allowsChromiumSchemes: Bool) -> [BrowserSuggestion] {
        guard let typedName = typedName(text) else { return [] }
        var rows: [BrowserSuggestion] = []
        for (index, host) in ChromiumPageRoute.completedHosts.enumerated() where host.hasPrefix(typedName) {
            guard let url = URL(string: "chrome://\(host)/"), let route = ChromiumPageRoute(url),
                  allowsChromiumSchemes || route.isCmuxOwned else { continue }
            var row = BrowserSuggestion(kind: .navigate, title: "chrome://\(host)", detail: "", url: url,
                                        score: score - Double(index) / 100)
            row.inlineCompletable = !typedName.isEmpty
            rows.append(row)
        }
        return rows
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
}
