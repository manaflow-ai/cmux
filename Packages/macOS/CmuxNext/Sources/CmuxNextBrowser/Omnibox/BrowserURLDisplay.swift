public import Foundation

/// How the address bar shows a URL.
public nonisolated enum BrowserURLDisplay {
    /// Compact text shown when the field is not being edited: no `https://`,
    /// no `www.`, no trailing slash on a bare host, percent escapes decoded.
    /// `http://` is kept so insecure pages stay recognizable; `chrome://`
    /// and `chrome-extension://` are kept as Chromium keeps them. A file
    /// shows its path, `~/…` under `home` (the user's home folder; tests
    /// pass their own), as a shell and the Markdown tab's mock show it.
    public static func displayText(for url: URL?, home: String = NSHomeDirectory()) -> String {
        guard let url else { return "" }
        if BrowserNewTabPage.isNewTabPage(url) || isRemoteDesktopPage(url) { return "" }
        if url.isFileURL { return tildePath(url.path(percentEncoded: false), home: home) }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = nil
        components.user = nil
        components.password = nil
        if host.lowercased().hasPrefix("www."), host.split(separator: ".").count > 2 {
            components.host = String(host.dropFirst(4))
        }
        var text = components.string ?? url.absoluteString
        if text.hasPrefix("//") { text.removeFirst(2) }
        if components.path == "/", components.query == nil, components.fragment == nil {
            text.removeLast()
        }
        text = text.removingPercentEncoding ?? text
        // Chromium's own pages keep their scheme, as Chromium shows them
        // (`chrome://extensions`, never a bare `extensions`).
        if let scheme, scheme == "http" || ChromiumInternalURL.chromiumSchemes.contains(scheme) {
            return scheme + "://" + text
        }
        return text
    }

    /// `path` with `home` (and only home, never a sibling such as
    /// `/Users/me2`) replaced by `~`.
    static func tildePath(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard home.count > 1 else { return path }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The host's UTF-16 range inside `displayText(for:)`, which the
    /// omnibar draws at full strength while the rest of the URL is dimmed
    /// (Chromium's host emphasis). Nil for file URLs and blank pages. `text`
    /// is the compact text or the full URL (`browser.omnibar.showFullURLs`).
    public static func hostRange(in text: String, for url: URL?) -> NSRange? {
        guard let url, !url.isFileURL, let fullHost = url.host(percentEncoded: false), !fullHost.isEmpty else { return nil }
        var host = fullHost
        if host.lowercased().hasPrefix("www."), host.split(separator: ".").count > 2 { host = String(host.dropFirst(4)) }
        let scheme = url.scheme?.lowercased() ?? ""
        let prefix = !scheme.isEmpty && text.lowercased().hasPrefix(scheme + "://") ? scheme + "://" : ""
        let rest = text.dropFirst(prefix.count).lowercased()
        for candidate in [host, fullHost] {
            let hostText = candidate.contains(":") && !candidate.hasPrefix("[") ? "[\(candidate)]" : candidate
            if rest.hasPrefix(hostText.lowercased()) { return NSRange(location: prefix.utf16.count, length: hostText.utf16.count) }
        }
        return nil
    }

    /// Full text placed in the field when editing starts.
    public static func editingText(for url: URL?) -> String {
        guard let url, !BrowserNewTabPage.isNewTabPage(url), !isRemoteDesktopPage(url) else { return "" }
        return url.absoluteString
    }

    /// A remote desktop tab (`cmux://remote-view?…`, the native Swift pane): its address is the
    /// tab's saved record, not a page, so the field stays empty (the tab title names the machine)
    /// and typing an address there opens that page instead.
    static func isRemoteDesktopPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "cmux" && url.host(percentEncoded: false)?.lowercased() == "remote-view"
    }

    /// Title for tab strips and window titles: the page title, else the host,
    /// else nil (callers show their own "New Tab").
    public static func title(for state: BrowserTabState) -> String? {
        if let title = state.title { return title }
        guard let url = state.url, !BrowserNewTabPage.isNewTabPage(url) else { return nil }
        return url.host() ?? url.lastPathComponent
    }
}
