import Foundation

struct FileSearchPreviewSlice: Equatable {
    let text: String
    /// Ranges (UTF-16 units, NSString-compatible) in `text` where the query
    /// occurs. Empty when the query is empty or has no occurrences in the
    /// preview.
    let matchRanges: [NSRange]
    let leadingEllipsis: Bool
}

enum FileSearchPreviewSlicer {
    /// How many UTF-16 units of leading context we try to keep before the
    /// first match before falling back to a leading ellipsis. Tuned so a
    /// typical Find-sidebar width can render meaningful leading context
    /// (function name + scope) rather than just a few chars before the match.
    static let defaultLeadingBudget = 40

    static func slice(
        preview: String,
        query: String,
        leadingBudget: Int = defaultLeadingBudget
    ) -> FileSearchPreviewSlice {
        // defensively strip outer whitespace, even though upstream
        // ripgrep-to-FileSearchResult already trims, we want absolute
        // certainty no row leads with a stray space/tab or trails with one.
        let trimmedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsPreview = trimmedPreview as NSString
        let nsQuery = query as NSString
        guard nsQuery.length > 0, nsPreview.length > 0 else {
            return FileSearchPreviewSlice(text: trimmedPreview, matchRanges: [], leadingEllipsis: false)
        }

        let firstMatch = nsPreview.range(
            of: query,
            options: [.caseInsensitive],
            range: NSRange(location: 0, length: nsPreview.length)
        )
        guard firstMatch.location != NSNotFound else {
            return FileSearchPreviewSlice(text: trimmedPreview, matchRanges: [], leadingEllipsis: false)
        }

        let needsLeadingEllipsis = firstMatch.location > leadingBudget
        let sliceStart = needsLeadingEllipsis ? firstMatch.location - leadingBudget : 0
        // trim whitespace at the slice boundary so we don't render
        // "…   foo" with awkward gap between the ellipsis and the first
        // visible char. Trailing whitespace is also stripped so rows that
        // happen to end on a tab/space don't render a phantom selection tail.
        // Using NSString index math (O(n)) instead of String.removeFirst/Last
        // (O(n) per char ⇒ O(n²) for long whitespace runs).
        var trimmedStart = sliceStart
        let nsPreviewEnd = nsPreview.length
        if needsLeadingEllipsis {
            while trimmedStart < nsPreviewEnd,
                  isWhitespace(nsPreview.character(at: trimmedStart)) {
                trimmedStart += 1
            }
        }
        var trimmedEnd = nsPreviewEnd
        while trimmedEnd > trimmedStart,
              isWhitespace(nsPreview.character(at: trimmedEnd - 1)) {
            trimmedEnd -= 1
        }

        let suffixLength = trimmedEnd - trimmedStart
        let suffixRange = NSRange(location: trimmedStart, length: suffixLength)
        let suffixTrimmed = nsPreview.substring(with: suffixRange)
        let text = needsLeadingEllipsis ? "\u{2026}" + suffixTrimmed : suffixTrimmed

        // collect every occurrence of the query in `text` for
        // highlight ranges. We re-scan inside `text` (not `nsPreview`) so the
        // ranges line up with the rendered string, `text` may carry a
        // prepended ellipsis and have a different leading/trailing whitespace
        // profile than the source slice.
        let nsText = text as NSString
        let textLength = nsText.length
        var matches: [NSRange] = []
        matches.reserveCapacity(4)
        var cursor = 0
        while cursor < textLength {
            let remaining = NSRange(location: cursor, length: textLength - cursor)
            let found = nsText.range(of: query, options: [.caseInsensitive], range: remaining)
            if found.location == NSNotFound { break }
            matches.append(found)
            cursor = found.location + max(found.length, 1)
        }

        return FileSearchPreviewSlice(text: text, matchRanges: matches, leadingEllipsis: needsLeadingEllipsis)
    }

    @inline(__always)
    private static func isWhitespace(_ unit: unichar) -> Bool {
        // Match `.whitespacesAndNewlines` for the BMP code units we care about
        // in source-line previews. Avoids bridging each character through
        // CharacterSet for every step of the trim loop.
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
             0x20, 0xA0,
             0x1680,
             0x2028, 0x2029,
             0x202F, 0x205F, 0x3000:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }
}
