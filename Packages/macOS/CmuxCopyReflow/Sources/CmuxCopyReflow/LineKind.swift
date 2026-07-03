import Foundation

/// Structural classification of a single line, used to decide whether it can
/// participate in paragraph reflow.
///
/// Classification is pure and depends only on the line's own text plus the
/// currently active fenced code block marker, which the caller threads through.
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
    /// A Markdown table row containing a pipe separator.
    case tableRow
    /// A list item (`-`, `*`, `+`, `•`, or `N.` / `N)`).
    case listItem
    /// A line that *is* a bare URL (optionally behind a single list/quote
    /// marker). Drives spaceless joining of wrapped URLs.
    case urlLine
    /// Ordinary prose — the only kind eligible for paragraph joining.
    case prose

    /// Classify a line. `activeFence` reflects the opening marker of an
    /// enclosing fenced block, if any; inside a fence, only a matching marker
    /// can classify as `.fenceDelimiter`.
    init(_ rawLine: Substring, activeFence: FenceMarker?) {
        let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }

        if let activeFence {
            if let marker = FenceMarker(closingLine: trimmed), marker.closes(activeFence) {
                self = .fenceDelimiter
            } else {
                self = .insideFence
            }
        } else if FenceMarker(trimmedLine: trimmed) != nil {
            self = .fenceDelimiter
        } else if trimmed.isEmpty {
            self = .blank
        } else if Self.isURLLine(trimmed) {
            // URL detection runs before blockquote/list so a bare URL behind a
            // single list or quote marker (R4) is recognised as a URL line.
            self = .urlLine
        } else if Self.isHeading(trimmed) {
            self = .heading
        } else if trimmed.first == ">" {
            self = .blockquote
        } else if Self.isListItem(trimmed) {
            self = .listItem
        } else if Self.isTableRow(trimmed) {
            self = .tableRow
        } else {
            self = .prose
        }
    }

    /// URL schemes that, when a line starts with one, mark the line as a URL.
    private static let urlPrefixes = ["http://", "https://", "www."]

    /// `#` .. `######` followed by a space (or end of line).
    private static func isHeading(_ trimmed: Substring) -> Bool {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = trimmed.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " "
    }

    /// Markdown table rows with outer pipes or separator rows. Rows without
    /// outer pipes are promoted by the reflow pass only when adjacent to a
    /// separator row, so shell pipelines stay eligible for command reflow.
    private static func isTableRow(_ trimmed: Substring) -> Bool {
        isOuterPipeTableRow(trimmed) || isMarkdownTableSeparator(trimmed)
    }

    static func isMarkdownTableCandidateRow(_ rawLine: Substring) -> Bool {
        let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }
        return !trimmed.isEmpty && trimmed.contains("|") && !isMarkdownTableSeparator(trimmed)
    }

    static func isMarkdownTableSeparatorRow(_ rawLine: Substring) -> Bool {
        let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }
        return isMarkdownTableSeparator(trimmed)
    }

    private static func isOuterPipeTableRow(_ trimmed: Substring) -> Bool {
        guard trimmed.first == "|", trimmed.last == "|" else { return false }
        return trimmed.filter { $0 == "|" }.count >= 2
    }

    private static func isMarkdownTableSeparator(_ trimmed: Substring) -> Bool {
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        for ch in trimmed {
            if ch != "|" && ch != "-" && ch != ":" && ch != " " && ch != "\t" {
                return false
            }
        }
        return true
    }

    /// `- `, `* `, `+ `, `• `, `N. `, or `N) ` (marker followed by a space).
    private static func isListItem(_ trimmed: Substring) -> Bool {
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
    private static func isURLLine(_ trimmed: Substring) -> Bool {
        let afterMarker = stripSingleLeadingMarker(trimmed)
        return !afterMarker.contains { $0 == " " || $0 == "\t" }
            && urlPrefixes.contains { afterMarker.lowercased().hasPrefix($0) }
    }

    /// Drop at most one leading list/quote marker (`- `, `1. `, `> `, etc.)
    /// so a URL behind such a marker is still recognised.
    private static func stripSingleLeadingMarker(_ trimmed: Substring) -> Substring {
        guard let first = trimmed.first else { return trimmed }
        if first == "-" || first == "*" || first == "+" || first == "•" || first == ">" {
            let rest = trimmed.dropFirst()
            if rest.first == " " {
                return rest.drop { $0 == " " }
            }
        }
        if first.isNumber {
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
                cursor = trimmed.index(after: cursor)
            }
            guard cursor < trimmed.endIndex,
                  trimmed[cursor] == "." || trimmed[cursor] == ")" else {
                return trimmed
            }
            let afterDelimiter = trimmed.index(after: cursor)
            guard afterDelimiter < trimmed.endIndex, trimmed[afterDelimiter] == " " else {
                return trimmed
            }
            return trimmed[afterDelimiter...].drop { $0 == " " }
        }
        return trimmed
    }
}

extension Substring {
    /// Number of leading space-equivalent columns (tabs count as one).
    var indentWidth: Int {
        var count = 0
        for ch in self {
            if ch == " " || ch == "\t" { count += 1 } else { break }
        }
        return count
    }

    /// Visible length used for the "is this line full?" wrap heuristic.
    var visibleLength: Int {
        count
    }
}
