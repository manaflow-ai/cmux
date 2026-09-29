public import Foundation

/// How the address bar shows a URL.
public nonisolated enum BrowserURLDisplay {
    /// Compact text shown when the field is not being edited: no `https://`,
    /// no `www.`, no trailing slash on a bare host, percent escapes decoded.
    /// `http://` is kept so insecure pages stay recognizable.
    public static func displayText(for url: URL?) -> String {
        guard let url else { return "" }
        if url.absoluteString == "about:blank" { return "" }
        if url.isFileURL { return url.path(percentEncoded: false) }

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
        return scheme == "http" ? "http://" + text : text
    }

    /// Full text placed in the field when editing starts.
    public static func editingText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    /// Title for tab strips and window titles: the page title, else the host,
    /// else nil (callers show their own "New Tab").
    public static func title(for state: BrowserTabState) -> String? {
        if let title = state.title { return title }
        guard let url = state.url, url.absoluteString != "about:blank" else { return nil }
        return url.host() ?? url.lastPathComponent
    }
}
