public import Foundation

/// URL rules for bookmarks: what counts as the same page, what the
/// favicon cache key is, and how a URL reads in a list.
public nonisolated enum BookmarkURL {
    /// Bookmarks compare canonical URLs: scheme and host are case-insensitive
    /// and an empty path is `/`. Fragments and queries count.
    public static func key(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        if let host = components.host { components.host = host.lowercased() }
        if components.host != nil, components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }

    /// The origin (`scheme://host[:port]`), the favicon cache key.
    public static func faviconKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// `github.com/foo` for `https://github.com/foo`; other schemes stay whole.
    public static func displayText(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
            if text.hasSuffix("/"), text.firstIndex(of: "/") == text.index(before: text.endIndex) { text.removeLast() }
            return text
        }
        return text
    }

    /// A URL a bookmark may hold: absolute, with a scheme.
    public static func isValid(_ url: URL) -> Bool {
        guard let scheme = url.scheme, !scheme.isEmpty else { return false }
        return url.absoluteString.utf8.count <= BookmarkLimits.urlBytes
    }

    /// A URL the user typed in an edit field, else nil. Text without a
    /// scheme gets `https://` (`example.com` becomes `https://example.com`).
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon]
            let rest = trimmed[trimmed.index(after: colon)...]
            // `localhost:3000` is a host and port, not a scheme.
            let isPort = !rest.isEmpty && rest.prefix { $0.isNumber }.count > 0 && !rest.hasPrefix("//")
            if !isPort, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }), let url = URL(string: trimmed),
               isValid(url) {
                return url
            }
            if isPort { return URL(string: "http://" + trimmed) }
        }
        guard trimmed.contains(".") || trimmed.hasPrefix("localhost") else { return nil }
        return URL(string: "https://" + trimmed)
    }
}

/// Size limits shared with the daemon (bookmarks.md section 1).
public nonisolated enum BookmarkLimits {
    public static let titleBytes = 4096
    public static let urlBytes = 65_536
    public static let nodesPerProfile = 100_000
    public static let depth = 64
}
