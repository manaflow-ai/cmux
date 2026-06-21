import Foundation

/// Chooses the inline find-needle to seed a panel's own search overlay after a
/// global-search hit is opened.
///
/// When a global-search result is activated, the destination panel (a browser
/// or markdown panel) opens its native find overlay pre-filled with a needle so
/// the matched text is highlighted in place. The needle is the first query
/// token that actually appears in the hit's combined text, falling back to the
/// first token when none of them are substrings of the hit text (the global
/// index can match on stemmed/prefixed terms the raw panel text does not
/// contain verbatim).
///
/// This is the pure selection rule, lifted out of the app target's
/// `GlobalSearchInlineSearch` caseless-enum namespace. The host tokenizes the
/// raw query (its FTS tokenizer is the single source of truth for token
/// splitting) and passes the lowercased tokens plus the hit's text fields; this
/// type holds only the matching decision so it is unit-testable without the
/// SQLite-backed search index.
public struct GlobalSearchNeedleResolver: Sendable, Equatable {
    /// The hit's text surfaces that a needle may be drawn from, in the priority
    /// order the legacy code joined them: snippet, title, location, anchor.
    public struct HitText: Sendable, Equatable {
        /// The matched snippet shown in the result row.
        public let snippet: String
        /// The result's title.
        public let title: String
        /// The result's location (panel/workspace breadcrumb).
        public let location: String
        /// The result's in-document anchor.
        public let anchor: String

        /// Creates the hit-text bundle from a global-search hit's fields.
        public init(snippet: String, title: String, location: String, anchor: String) {
            self.snippet = snippet
            self.title = title
            self.location = location
            self.anchor = anchor
        }
    }

    /// Creates a resolver. The type is stateless; the initializer exists so the
    /// host constructs an instance it holds rather than calling a static-only
    /// utility.
    public init() {}

    /// Selects the inline needle for `tokens` against `hitText`.
    ///
    /// - Parameters:
    ///   - tokens: The lowercased, non-empty query tokens, already split by the
    ///     host's FTS tokenizer.
    ///   - hitText: The hit's text surfaces.
    /// - Returns: The first token contained in the combined lowercased hit text,
    ///   or the first token when none match; `nil` when `tokens` is empty.
    public func needle(tokens: [String], hitText: HitText) -> String? {
        guard !tokens.isEmpty else { return nil }

        let combined = [
            hitText.snippet,
            hitText.title,
            hitText.location,
            hitText.anchor
        ].joined(separator: "\n").lowercased()

        return tokens.first { combined.contains($0) } ?? tokens[0]
    }
}
