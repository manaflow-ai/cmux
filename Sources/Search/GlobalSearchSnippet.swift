import Foundation

/// Builds the one-line excerpt a Global Search row shows under its title.
///
/// FTS5 `snippet()` walks every phrase instance in each matched document. On
/// the 400k-character documents the index holds, a one-letter prefix query
/// spent seconds there. The index now ranks without it, and this builds the
/// excerpt for the final rows only: the first word-start occurrence of the
/// longest query token, with context on both sides.
enum GlobalSearchSnippet {
    static let leadingContext = 48
    static let trailingContext = 110
    /// Occurrences checked for a word start before the first occurrence wins.
    static let wordStartSearchLimit = 64

    /// - Parameters:
    ///   - text: The document's stored text.
    ///   - tokens: `SearchIndex.queryTokens(for:)` of the query.
    /// - Returns: A whitespace-collapsed excerpt around the match, or the start
    ///   of the text when no token occurs in it (a title-only match).
    static func excerpt(text: String, tokens: [String]) -> String {
        let source = text as NSString
        guard source.length > 0 else { return "" }
        let match = tokens
            .sorted { $0.count > $1.count }
            .lazy
            .compactMap { wordStartRange(of: $0, in: source) }
            .first

        let window: NSRange
        if let match {
            let start = max(0, match.location - leadingContext)
            let end = min(source.length, NSMaxRange(match) + trailingContext)
            window = NSRange(location: start, length: end - start)
        } else {
            window = NSRange(location: 0, length: min(source.length, leadingContext + trailingContext))
        }
        let safeWindow = source.rangeOfComposedCharacterSequences(for: window)
        let excerpt = source.substring(with: safeWindow)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let prefix = safeWindow.location > 0 ? "..." : ""
        let suffix = NSMaxRange(safeWindow) < source.length ? "..." : ""
        return prefix + excerpt + suffix
    }

    /// The first occurrence of `token` that starts a word, matching FTS5's
    /// prefix semantics; falls back to the first occurrence anywhere.
    static func wordStartRange(of token: String, in source: NSString) -> NSRange? {
        guard !token.isEmpty else { return nil }
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchRange = NSRange(location: 0, length: source.length)
        var firstMatch: NSRange?
        for _ in 0..<wordStartSearchLimit {
            let found = source.range(of: token, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            if firstMatch == nil { firstMatch = found }
            if found.location == 0 || !isWordCharacter(source.character(at: found.location - 1)) {
                return found
            }
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return firstMatch
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
