import Foundation
import Combine

/// Observable search state for find-in-page in markdown panels.
/// Searches the raw markdown content string (case-insensitive).
final class MarkdownSearchState: ObservableObject {
    @Published var needle: String
    @Published var selected: UInt?
    @Published var total: UInt?

    /// Character ranges of each match in the content string.
    /// Currently only used for total count — the WKWebView handles highlighting via JS.
    @Published var matchRanges: [Range<String.Index>] = []

    init(needle: String = "") {
        self.needle = needle
    }

    /// Recompute matches against the given content string.
    /// Uses `.caseInsensitive` option for correct Unicode handling.
    func search(in content: String) {
        guard !needle.isEmpty else {
            matchRanges = []
            total = 0
            selected = nil
            return
        }

        var ranges: [Range<String.Index>] = []
        var searchStart = content.startIndex

        while searchStart < content.endIndex,
              let range = content.range(
                  of: needle,
                  options: .caseInsensitive,
                  range: searchStart..<content.endIndex
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        matchRanges = ranges
        total = UInt(ranges.count)
        selected = ranges.isEmpty ? nil : 0
    }

    /// Move to the next match. Wraps around.
    func selectNext() {
        guard let current = selected, let count = total, count > 0 else { return }
        selected = (current + 1) % count
    }

    /// Move to the previous match. Wraps around.
    func selectPrevious() {
        guard let current = selected, let count = total, count > 0 else { return }
        selected = current == 0 ? count - 1 : current - 1
    }
}
