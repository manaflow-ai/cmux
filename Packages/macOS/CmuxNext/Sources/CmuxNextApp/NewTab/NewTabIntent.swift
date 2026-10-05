import CmuxNextBrowser
import Foundation

/// What the new tab field's text means (plans/cmux-next/new-tab.md section
/// 3.1), for the paths with no page: CLI, MCP, palette. The page decides
/// with `webviews/src/agent-session/acpmux/newTabIntent.ts`; both pass
/// `webviews/test/fixtures/new-tab-intents.json`.
nonisolated enum NewTabIntent: Equatable, Sendable {
    case none
    /// `!` first: the tab becomes a terminal with `command` typed (not run).
    case terminal(command: String)
    /// An address the browser loads.
    case url(String)
    /// Plain text: a prompt for an agent. A web search is an explicit
    /// choice (a row, `newTab.submit --arg search=true`), never a mode (R86).
    case prompt(String)

    static let terminalPrefix: Character = "!"

    /// File extensions that are also top-level domains or look like one: a
    /// bare `name.ext` with one is text; a scheme, `www.`, a port or a path
    /// makes it an address (decision Q4).
    static let fileExtensions: Set<String> = [
        "c", "cc", "cfg", "cjs", "conf", "cpp", "cs", "css", "csv", "dart", "env", "ex", "exs", "gif", "go",
        "gradle", "gz", "h", "hpp", "html", "ini", "java", "jpeg", "jpg", "js", "json", "jsx", "kt", "lock",
        "log", "lua", "md", "mdx", "mjs", "mts", "nix", "pdf", "php", "pl", "plist", "png", "py", "rb", "rs",
        "scss", "sh", "sql", "svelte", "svg", "swift", "tar", "toml", "ts", "tsx", "txt", "vue", "xml",
        "yaml", "yml", "zig", "zip", "zsh",
    ]

    static func classify(_ input: String, home: URL? = FileManager.default.homeDirectoryForCurrentUser) -> NewTabIntent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .none }
        if trimmed.first == terminalPrefix {
            return .terminal(command: trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let url = url(for: trimmed, home: home) { return .url(url.absoluteString) }
        return .prompt(trimmed)
    }

    /// BrowserURLResolver's address (WebKit rules), minus a bare file name.
    /// Without a home folder, `~` and `~/path` are text.
    static func url(for text: String, home: URL?) -> URL? {
        if text == "~" || text.hasPrefix("~/"), home == nil { return nil }
        if looksLikeFileName(text) { return nil }
        let resolver = BrowserURLResolver(homeDirectory: home ?? URL(filePath: "/"))
        return resolver.url(for: text)
    }

    /// `node.js`, `readme.md`: one token, no port, no path, no `www.`,
    /// ending in a file extension.
    static func looksLikeFileName(_ text: String) -> Bool {
        if text.contains(where: { "/?#:".contains($0) || $0.isWhitespace }) { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("www.") { return false }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return false }
        return fileExtensions.contains(String(lower[lower.index(after: dot)...]))
    }
}

/// The fixture's shape: `{"kind": "terminal", "command": "ls"}` and so on,
/// the same JSON the page's `NewTabIntent` type has.
nonisolated extension NewTabIntent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, command, url, text }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "terminal": self = .terminal(command: try container.decode(String.self, forKey: .command))
        case "url": self = .url(try container.decode(String.self, forKey: .url))
        case "prompt": self = .prompt(try container.decode(String.self, forKey: .text))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try container.encode("none", forKey: .kind)
        case .terminal(let command):
            try container.encode("terminal", forKey: .kind)
            try container.encode(command, forKey: .command)
        case .url(let url):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
        case .prompt(let text):
            try container.encode("prompt", forKey: .kind)
            try container.encode(text, forKey: .text)
        }
    }
}
