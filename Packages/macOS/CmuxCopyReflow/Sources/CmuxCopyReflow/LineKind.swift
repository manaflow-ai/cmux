import Foundation

/// Structural classification of a single line, used to decide whether it can
/// participate in paragraph reflow.
///
/// Classification is pure and depends only on the line's own text plus whether
/// we are currently inside a fenced code block (`insideFence`), which the
/// caller threads through.
public enum LineKind: Equatable, Sendable {
    /// Empty or whitespace-only.
    case blank
    /// A ``` ``` ``` fence delimiter (opening or closing).
    case fenceDelimiter
    /// Any line while inside a fenced code block (not a delimiter).
    case insideFence
    /// A Markdown ATX heading, `#` through `######`.
    case heading
    /// A blockquote line (`>` prefix).
    case blockquote
    /// A table row (`|`-delimited, or a `---|---` separator).
    case tableRow
    /// A list item (`-`, `*`, `+`, `•`, or `N.` / `N)`).
    case listItem
    /// A line that *is* a bare URL (optionally behind a single list/quote
    /// marker). Drives spaceless joining of wrapped URLs.
    case urlLine
    /// Ordinary prose — the only kind eligible for paragraph joining.
    case prose
}

enum LineClassifier {
    /// URL schemes that, when a line starts with one, mark the line as a URL.
    static let urlPrefixes = ["http://", "https://", "www."]

    /// Number of leading space-equivalent columns (tabs count as one).
    static func indentWidth(of line: Substring) -> Int {
        var count = 0
        for ch in line {
            if ch == " " || ch == "\t" { count += 1 } else { break }
        }
        return count
    }

    /// Visible length used for the "is this line full?" wrap heuristic.
    static func visibleLength(of line: Substring) -> Int {
        line.count
    }

    /// Classify a line. `insideFence` reflects the state *before* this line is
    /// considered; a fence delimiter both classifies as `.fenceDelimiter` and
    /// (for the caller) toggles that state.
    static func classify(_ rawLine: Substring, insideFence: Bool) -> LineKind {
        let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }

        if isFenceDelimiter(trimmed) {
            return .fenceDelimiter
        }
        if insideFence {
            return .insideFence
        }
        if trimmed.isEmpty {
            return .blank
        }
        // URL detection runs before blockquote/list so a bare URL behind a
        // single list or quote marker (R4) is recognised as a URL line.
        if isURLLine(trimmed) {
            return .urlLine
        }
        if isHeading(trimmed) {
            return .heading
        }
        if trimmed.first == ">" {
            return .blockquote
        }
        if isTableRow(trimmed) {
            return .tableRow
        }
        if isListItem(trimmed) {
            return .listItem
        }
        return .prose
    }

    /// A fence delimiter is a line whose first non-space content is ``` ``` ```
    /// (three or more backticks) or `~~~`, optionally followed by an info
    /// string.
    static func isFenceDelimiter(_ trimmed: Substring) -> Bool {
        let backticks = trimmed.prefix { $0 == "`" }
        if backticks.count >= 3 { return true }
        let tildes = trimmed.prefix { $0 == "~" }
        if tildes.count >= 3 { return true }
        return false
    }

    /// `#` .. `######` followed by a space (or end of line).
    static func isHeading(_ trimmed: Substring) -> Bool {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = trimmed.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " "
    }

    static func isTableRow(_ trimmed: Substring) -> Bool {
        guard let first = trimmed.first else { return false }
        // A piped row: starts and ends with `|`.
        if first == "|" {
            let last = trimmed.reversed().first { $0 != " " }
            return last == "|"
        }
        // A header separator like `---|---` or `:--|--:`.
        if trimmed.contains("|"),
           trimmed.allSatisfy({ $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " }) {
            return true
        }
        return false
    }

    /// `- `, `* `, `+ `, `• `, `N. `, or `N) ` (marker followed by a space).
    static func isListItem(_ trimmed: Substring) -> Bool {
        guard let first = trimmed.first else { return false }
        if first == "-" || first == "*" || first == "+" || first == "•" {
            let rest = trimmed.dropFirst()
            return rest.first == " "
        }
        // Ordered list: one or more digits then `.` or `)` then space.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let marker = afterDigits.first, marker == "." || marker == ")" {
                let rest = afterDigits.dropFirst()
                return rest.first == " "
            }
        }
        return false
    }

    /// True when the line *is* a URL: optionally one leading list/quote marker,
    /// then a URL prefix. "Mentions a URL somewhere" does not count.
    static func isURLLine(_ trimmed: Substring) -> Bool {
        let afterMarker = stripSingleLeadingMarker(trimmed)
        return urlPrefixes.contains { afterMarker.lowercased().hasPrefix($0) }
    }

    /// Drop at most one leading list/quote marker (`- `, `* `, `+ `, `• `,
    /// `> `) so a URL behind such a marker is still recognised.
    static func stripSingleLeadingMarker(_ trimmed: Substring) -> Substring {
        guard let first = trimmed.first else { return trimmed }
        if first == "-" || first == "*" || first == "+" || first == "•" || first == ">" {
            let rest = trimmed.dropFirst()
            if rest.first == " " {
                return rest.drop { $0 == " " }
            }
        }
        return trimmed
    }
}
