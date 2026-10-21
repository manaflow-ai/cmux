import Foundation

extension ImportedSearchEngine {
    /// The search addresses of the engines Firefox and Safari ship, which their
    /// settings name without a template (Firefox's built-in `id`, Safari's
    /// display name or provider id): the first entry whose key is in the name.
    static let wellKnown: [(key: String, name: String, search: String)] = [
        ("google", "Google", "https://www.google.com/search?q={searchTerms}"),
        ("bing", "Bing", "https://www.bing.com/search?q={searchTerms}"),
        ("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q={searchTerms}"),
        ("ddg", "DuckDuckGo", "https://duckduckgo.com/?q={searchTerms}"),
        ("ecosia", "Ecosia", "https://www.ecosia.org/search?q={searchTerms}"),
        ("yahoo", "Yahoo", "https://search.yahoo.com/search?p={searchTerms}"),
        ("baidu", "Baidu", "https://www.baidu.com/s?wd={searchTerms}"),
        ("qwant", "Qwant", "https://www.qwant.com/?q={searchTerms}"),
    ]

    /// The well-known engine one of `names` names ("google@search.mozilla.orgdefault", "com.google.www").
    static func wellKnown(named names: [String?]) -> ImportedSearchEngine? {
        let lowered = names.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard let match = wellKnown.first(where: { entry in lowered.contains { $0.contains(entry.key) } }) else { return nil }
        return ImportedSearchEngine(name: match.name, search: match.search)
    }
}
