import Foundation

/// What New Tab from Text's one field means (the Mac's `NewTabIntent`, `newTab.submit`):
/// `!` first is a terminal with the command typed, an address opens a browser tab, and any
/// other text is a prompt for a new agent chat. A web search is an explicit choice (its own
/// row), never a mode, as on the Mac (R86).
public enum NewTabText: Equatable, Sendable {
    case none
    /// `!` first: a terminal with `command` typed, not run.
    case terminal(command: String)
    case address(URL)
    case prompt(String)

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .none
        } else if trimmed.first == "!" {
            self = .terminal(command: trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let url = Self.address(trimmed) {
            self = .address(url)
        } else {
            self = .prompt(trimmed)
        }
    }

    /// The text as the explicit Search row searches it.
    public static func searchURL(_ text: String) -> URL? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// An http(s) address, `host:port[/path]`, or a dotted host with no spaces; never a bare
    /// file name (`readme.md`, `node.js`), which the Mac reads as text (decision Q4).
    static func address(_ text: String) -> URL? {
        if text.contains(where: \.isWhitespace) { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
            return url
        }
        if text.wholeMatch(of: /[A-Za-z0-9.-]+:[0-9]{1,5}(\/.*)?/) != nil { return URL(string: "http://\(text)") }
        guard text.contains("."), !looksLikeFileName(text), !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        // A dotted host whose last label is a top-level domain (letters), or an IPv4 address:
        // never a version (`1.2.3`, `v1.2`).
        guard host.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/) != nil
            || host.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){3}/) != nil else { return nil }
        return URL(string: "https://\(text)")
    }

    /// The Mac's `NewTabIntent.fileExtensions` rule: one token, no path, no `www.`, ending in
    /// a file extension.
    static func looksLikeFileName(_ text: String) -> Bool {
        if text.contains(where: { "/?#:".contains($0) }) { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("www.") { return false }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return false }
        return fileExtensions.contains(String(lower[lower.index(after: dot)...]))
    }

    static let fileExtensions: Set<String> = [
        "c", "cc", "cfg", "cjs", "conf", "cpp", "cs", "css", "csv", "dart", "env", "ex", "exs", "gif", "go",
        "gradle", "gz", "h", "hpp", "html", "ini", "java", "jpeg", "jpg", "js", "json", "jsx", "kt", "lock",
        "log", "lua", "md", "mdx", "mjs", "mts", "nix", "pdf", "php", "pl", "plist", "png", "py", "rb", "rs",
        "scss", "sh", "sql", "svelte", "svg", "swift", "tar", "toml", "ts", "tsx", "txt", "vue", "xml",
        "yaml", "yml", "zig", "zip", "zsh",
    ]
}
