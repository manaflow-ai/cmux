public import Foundation

/// Builds the attributed form of a row label with the filter's matched
/// characters emphasised.
///
/// Pure string work, deliberately separate from any view: the sidebar draws
/// rows through AppKit and SwiftUI in different places, and both need the same
/// emphasis decisions from the same match data.
public struct SidebarFilterHighlightedText: Sendable {
    /// One run of the label, and whether the filter matched it.
    public struct Run: Sendable, Equatable {
        /// The run's text.
        public let text: String
        /// Whether this run should be emphasised as a match.
        public let isMatch: Bool

        /// Creates a run.
        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// Splits `displayText` into alternating unmatched and matched runs.
    ///
    /// Adjacent matched characters collapse into one run, so a label renders as
    /// few attribute changes as possible rather than one per character.
    ///
    /// - Parameters:
    ///   - displayText: The label exactly as the row draws it.
    ///   - ranges: Ascending, non-overlapping match ranges in character offsets,
    ///     as returned by ``SidebarFilterMatch/highlightRanges(for:in:)``.
    /// - Returns: Runs in order; concatenating their text reproduces
    ///   `displayText` exactly. An empty or out-of-bounds range set yields a
    ///   single unmatched run.
    public static func runs(
        displayText: String,
        ranges: [Range<Int>]
    ) -> [Run] {
        let characters = Array(displayText)
        guard !ranges.isEmpty else {
            return characters.isEmpty ? [] : [Run(text: displayText, isMatch: false)]
        }
        guard ranges.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= characters.count })
        else {
            return [Run(text: displayText, isMatch: false)]
        }

        var runs: [Run] = []
        var cursor = 0
        for range in ranges {
            // A caller that hands over unsorted or overlapping ranges would
            // otherwise duplicate or drop characters; skip rather than corrupt
            // the label.
            guard range.lowerBound >= cursor else { continue }
            if range.lowerBound > cursor {
                runs.append(Run(
                    text: String(characters[cursor..<range.lowerBound]),
                    isMatch: false
                ))
            }
            runs.append(Run(text: String(characters[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < characters.count {
            runs.append(Run(text: String(characters[cursor...]), isMatch: false))
        }
        return runs
    }
}
