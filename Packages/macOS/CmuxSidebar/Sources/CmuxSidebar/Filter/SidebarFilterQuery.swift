public import CmuxFoundation

/// A sidebar filter query: the raw text the user typed, split into the text to
/// match and the optional field it was restricted to.
///
/// A leading sigil scopes the search to one field (`@` branch, `#` group, `:`
/// port, `/` directory); everything else searches every field. The sigil is
/// stripped from ``searchText`` so `/repos` matches the directory text
/// `~/repos/cmux` rather than requiring a literal leading slash.
///
/// ```swift
/// let query = SidebarFilterQuery("@fix-drag")
/// query.restrictedField  // .branch
/// query.searchText       // "fix-drag"
/// ```
///
/// A directory query keeps its slash when the user typed a rooted path, since
/// `/Users/me` reads as a path fragment rather than a scoped search.
public struct SidebarFilterQuery: Sendable, Equatable {
    /// The unmodified text the user typed.
    public let rawText: String
    /// The text to fuzzy-match, with any scoping sigil removed.
    public let searchText: String
    /// The field this query was scoped to, or nil to search every field.
    public let restrictedField: SidebarFilterField?

    /// Whether this query selects everything (nothing to match against).
    public var isEmpty: Bool {
        searchText.isEmpty
    }

    /// The fields this query should be scored against, in declaration order.
    public var fields: [SidebarFilterField] {
        guard let restrictedField else { return SidebarFilterField.allCases }
        return [restrictedField]
    }

    /// Parses `rawText` into a scoped query.
    ///
    /// - Parameter rawText: Text straight from the filter field.
    public init(_ rawText: String) {
        self.rawText = rawText
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sigil = trimmed.first,
              let field = SidebarFilterField.allCases.first(where: { $0.querySigil == sigil }),
              Self.sigilScopesQuery(sigil: sigil, trimmed: trimmed) else {
            self.searchText = trimmed
            self.restrictedField = nil
            return
        }
        self.searchText = String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.restrictedField = field
    }

    /// Whether a leading sigil should be read as a scope rather than as part of
    /// the search text.
    ///
    /// `/Users/me/src` is a path the user is searching for, not a directory
    /// scope followed by `Users/me/src` - a rooted path keeps its slash. Every
    /// other sigil always scopes.
    private static func sigilScopesQuery(sigil: Character, trimmed: String) -> Bool {
        guard sigil == "/" else { return true }
        return !trimmed.dropFirst().contains("/")
    }

    /// The fuzzy matcher for this query, or nil when the query is empty.
    public func makeMatcher() -> FuzzyMatcher? {
        guard !isEmpty else { return nil }
        let matcher = FuzzyMatcher(query: searchText)
        guard !matcher.preparedQuery.isEmpty else { return nil }
        return matcher
    }
}
