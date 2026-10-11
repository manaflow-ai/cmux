public import Foundation

/// Phase B rules (plans/cmux-next/omnibar-suggestions.md): which input may
/// leave the machine, how a suggest response reads, and the rows it makes.
/// Pure.
public nonisolated struct OmniboxRemoteSuggestions {
    public init() {}

    /// Remote rows score below local matches: 200, 199, ...
    static let topScore: Double = 200

    /// Whether `text` may be sent to the search engine. Never for input that
    /// reads as an address (the URL resolver says so), a file path, a
    /// scheme, an IP address, `localhost` or a `host:port`, and never past
    /// `OmniboxText.maxInputLength`: private addresses stay private.
    public static func allows(_ text: String, resolver: OmniboxResolver) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= OmniboxText.maxInputLength else { return false }
        if case .url = resolver.destination(for: trimmed) { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("/") || lowered.hasPrefix("~") || lowered.hasPrefix("file:") || lowered.contains("://") { return false }
        let first = lowered.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? lowered
        if first.hasPrefix("localhost") || first.hasPrefix("[") { return false }
        if first.split(separator: ".").count == 4, first.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return false }
        // host:port ("nas:8080", "127.0.0.1:3000").
        if let colon = first.lastIndex(of: ":"), !first[first.index(after: colon)...].isEmpty,
           first[first.index(after: colon)...].allSatisfy(\.isNumber) { return false }
        return true
    }

    /// `text` without a leading "=" and spaces, as an answer reads.
    static func answerText(_ text: String) -> String {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.hasPrefix("=") { trimmed = trimmed.dropFirst() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// The suggestions of an OpenSearch JSON response (`[query, [s1, s2, ...], ...]`),
    /// in order. Bytes that are not UTF-8 read as Latin-1 (Google's
    /// `client=firefox` answers in ISO-8859-1 for some languages).
    public static func parse(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard let array = object as? [Any], array.count >= 2, let suggestions = array[1] as? [Any] else { return [] }
        return suggestions.compactMap { $0 as? String }
    }

    /// Search rows for `suggestions` of the typed `query`: no repeat of the
    /// query itself, of one another, or of the calculator's `answer` ("4"
    /// or "= 4" when the answer row already says "= 4"), at most `limit`,
    /// never inline-completable.
    public static func rows(_ suggestions: [String], query: String, engine: BrowserSearchEngine, limit: Int,
                            answer: String? = nil) -> [BrowserSuggestion] {
        var seen: Set<String> = [query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        var rows: [BrowserSuggestion] = []
        for suggestion in suggestions where rows.count < limit {
            let text = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if let answer, answerText(text) == answer { continue }
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted, let url = engine.searchURL(for: text) else { continue }
            var row = BrowserSuggestion(kind: .search, title: text, detail: "", url: url, score: topScore - Double(rows.count))
            row.inlineCompletable = false
            rows.append(row)
        }
        return rows
    }
}

/// What the App's settings decide for every suggestion engine
/// (`browser.searchEngine`, `browser.customSearchEngine`, `browser.omnibar.*`).
public nonisolated struct OmniboxConfiguration: Hashable, Sendable {
    public var searchEngine: BrowserSearchEngine = .google
    public var remoteSuggestions = true
    public var inlineAutocomplete = true
    public var maxRows = 8
    /// `browser.omnibar.calculator`: arithmetic answers.
    public var calculator = true

    public init(searchEngine: BrowserSearchEngine = .google, remoteSuggestions: Bool = true, inlineAutocomplete: Bool = true,
                maxRows: Int = 8, calculator: Bool = true) {
        self.searchEngine = searchEngine
        self.remoteSuggestions = remoteSuggestions
        self.inlineAutocomplete = inlineAutocomplete
        self.maxRows = maxRows
        self.calculator = calculator
    }
}
