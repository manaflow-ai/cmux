public import Foundation

/// One omnibar suggestion row: a search, a direct navigation, a history entry,
/// a switch-to-open-tab action, or a remote search prediction.
///
/// Identity (`id`) is stable across refreshes so SwiftUI rows do not tear down
/// and rebuild while typing. The display/match helpers (`navigableCompletion`,
/// `matchTitle`, `matchesTypedPrefix`, `supportsAutocompletion`) were lifted
/// from the legacy top-level `omnibarSuggestion*` functions onto the type that
/// owns the data.
public struct OmnibarSuggestion: Identifiable, Hashable, Sendable {
    /// What the suggestion row does and the data it carries.
    public enum Kind: Hashable, Sendable {
        case search(engineName: String, query: String)
        case navigate(url: String)
        case history(url: String, title: String?)
        case switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?)
        case remote(query: String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    // Stable identity prevents row teardown/rebuild flicker while typing.
    public var id: String {
        switch kind {
        case .search(let engineName, let query):
            return "search|\(engineName.lowercased())|\(query.lowercased())"
        case .navigate(let url):
            return "navigate|\(url.lowercased())"
        case .history(let url, _):
            return "history|\(url.lowercased())"
        case .switchToTab(let tabId, let panelId, let url, _):
            return "switch-tab|\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
        case .remote(let query):
            return "remote|\(query.lowercased())"
        }
    }

    public var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .navigate(let url): return url
        case .history(let url, _): return url
        case .switchToTab(_, _, let url, _): return url
        case .remote(let q): return q
        }
    }

    public var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .navigate(let url):
            return Self.displayURLText(for: url)
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .remote(let q):
            return q
        }
    }

    public var listText: String {
        switch kind {
        case .history(let url, let title), .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            guard !titleOneline.isEmpty else { return Self.displayURLText(for: url) }
            return "\(titleOneline) — \(Self.displayURLText(for: url))"
        default:
            return primaryText
        }
    }

    public var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        default:
            return nil
        }
    }

    public var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return String(localized: "browser.switchToTab", defaultValue: "Switch to tab")
        default:
            return nil
        }
    }

    public var isHistoryRemovable: Bool {
        if case .history = kind { return true }
        return false
    }

    /// The completion string used for inline autocompletion: the navigable URL
    /// for navigate/history/switch-to-tab rows, `nil` for search/remote rows.
    public var navigableCompletion: String? {
        switch kind {
        case .navigate(let url):
            return url
        case .history(let url, _):
            return url
        case .switchToTab(_, _, let url, _):
            return url
        default:
            return nil
        }
    }

    /// The page title used for prefix matching, when the row carries one.
    public var matchTitle: String? {
        switch kind {
        case .history(_, let title):
            return title
        case .switchToTab(_, _, _, let title):
            return title
        default:
            return nil
        }
    }

    /// Whether this suggestion's completion (or title) prefixes `typedText`,
    /// honoring scheme/`www` variants so a typed host matches a fuller URL.
    public func matchesTypedPrefix(typedText: String) -> Bool {
        guard let suggestionCompletion = navigableCompletion else { return false }
        return Self.matchesTypedPrefix(
            typedText: typedText,
            suggestionCompletion: suggestionCompletion,
            suggestionTitle: matchTitle
        )
    }

    /// Shared prefix-match used both with a suggestion's own completion and with
    /// an arbitrary completion string.
    static func matchesTypedPrefix(
        typedText: String,
        suggestionCompletion: String,
        suggestionTitle: String? = nil
    ) -> Bool {
        let trimmedQuery = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }

        let query = trimmedQuery.lowercased()
        let trimmedCompletion = suggestionCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCompletion.isEmpty else { return false }
        let loweredCompletion = trimmedCompletion.lowercased()

        let schemeStripped = trimmedCompletion.omnibarSchemeStripped
        let schemeAndWWWStripped = trimmedCompletion.omnibarSchemeAndWWWStripped
        let typedIncludesScheme = query.hasPrefix("https://") || query.hasPrefix("http://")
        let typedIncludesWWWPrefix = query.hasPrefix("www.")

        if typedIncludesScheme, loweredCompletion.hasPrefix(query) { return true }
        if schemeStripped.hasPrefix(query) { return true }
        if !typedIncludesWWWPrefix && schemeAndWWWStripped.hasPrefix(query) { return true }

        let normalizedTitle = suggestionTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !normalizedTitle.isEmpty && normalizedTitle.hasPrefix(query) {
            return true
        }

        return false
    }

    /// Whether `query` can inline-autocomplete to this suggestion: only
    /// navigate/history/switch-to-tab rows with a TLD-bearing host that prefixes
    /// the typed text.
    public func supportsAutocompletion(query: String) -> Bool {
        if case .search = kind { return false }
        if case .remote = kind { return false }
        guard let completion = navigableCompletion else { return false }
        // Reject URLs whose host lacks a TLD (e.g. "https://news." → host "news").
        if let components = URLComponents(string: completion),
           let host = components.host?.lowercased() {
            let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !trimmedHost.contains(".") { return false }
        }
        return Self.matchesTypedPrefix(
            typedText: query,
            suggestionCompletion: completion,
            suggestionTitle: matchTitle
        )
    }

    public static func history(_ entry: BrowserHistoryEntry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    public static func history(url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: url, title: title))
    }

    public static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    public static func navigate(url: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .navigate(url: url))
    }

    public static func switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .switchToTab(tabId: tabId, panelId: panelId, url: url, title: title))
    }

    public static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
    }

    private static func singleLineText(_ value: String?) -> String {
        var normalized = (value ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("  ") {
            let collapsed = normalized.replacingOccurrences(of: "  ", with: " ")
            if collapsed == normalized { break }
            normalized = collapsed
        }
        return normalized
    }

    private static func displayURLText(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              var host = components.host else {
            return rawURL
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        host = host.lowercased()

        var result = host
        if let port = components.port {
            result += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            result += path
        } else if path == "/" {
            result += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }

        if result.isEmpty { return rawURL }
        return result
    }
}
