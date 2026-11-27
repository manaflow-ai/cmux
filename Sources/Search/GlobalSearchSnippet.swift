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
    /// Joins an agent session's messages, which the stored text keeps one per line.
    static let messageSeparator = " \u{00B7} "

    /// - Parameters:
    ///   - text: The document's stored text.
    ///   - tokens: `SearchIndex.queryTokens(for:)` of the query.
    ///   - phrases: `SearchIndex.queryPhrases(for:)`, looked for before tokens.
    ///   - lineSeparator: What joins the excerpt's lines.
    /// - Returns: A whitespace-collapsed excerpt around the match, or the start
    ///   of the text when no token occurs in it (a title-only match), without
    ///   private-use glyphs (prompt icon fonts) the system font can't draw.
    static func excerpt(
        text: String,
        tokens: [String],
        phrases: [String] = [],
        lineSeparator: String = " "
    ) -> String {
        let source = text as NSString
        guard source.length > 0 else { return "" }
        let match = (phrases.sorted { $0.count > $1.count } + tokens.sorted { $0.count > $1.count })
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
        let excerpt = displayable(source.substring(with: safeWindow))
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: lineSeparator)
        let prefix = safeWindow.location > 0 ? "..." : ""
        let suffix = NSMaxRange(safeWindow) < source.length ? "..." : ""
        return prefix + excerpt + suffix
    }

    /// Drops private-use scalars (Nerd Font and Powerline prompt glyphs) and
    /// replacement characters, which render as boxes in the palette's font.
    static func displayable(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isUndrawable) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { !isUndrawable($0) })
        return String(scalars)
    }

    private static func isUndrawable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD, 0xFFFD:
            return true
        default:
            return false
        }
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
