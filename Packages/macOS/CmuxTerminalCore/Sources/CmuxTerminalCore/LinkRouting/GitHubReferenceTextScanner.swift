import Foundation

/// Finds every GitHub reference in a run of plain text, with the range each
/// one occupies.
///
/// ``TerminalGitHubReferenceDetector`` answers about the token under a pointer,
/// which is what a click needs. Text that is rendered rather than pointed at
/// needs the opposite: every reference at once, and where each one sits, so a
/// renderer can turn them into links.
///
/// This deliberately knows nothing about markup. Callers hand it the text of
/// one already-parsed run, so code spans, existing links and anything else the
/// parser has already claimed never reach it. Scanning raw markdown here would
/// mean re-implementing the parser badly and linkifying the inside of a fenced
/// block.
///
/// One whitespace-delimited segment yields at most one reference, which is the
/// same token model ``TerminalGitHubReferenceDetector`` uses for a click, so
/// text finds exactly what a pointer would. Two references run together without
/// a space, as in `#847;#848` or `#847/#848`, therefore yield none rather than
/// two: the combined segment parses as neither. A possessive such as `#847's`
/// is the same case. Splitting a segment further would linkify text a click on
/// the same characters does nothing for, and the two behaviors disagreeing is
/// worse than this gap.
public struct GitHubReferenceTextScanner: Sendable {
    /// One reference and the text it occupies.
    public struct Hit: Equatable, Sendable {
        /// The reference the text names.
        public let reference: TerminalGitHubReference
        /// The range of ``TerminalGitHubReference/rawToken`` in the scanned
        /// text, with any wrapping punctuation left outside it.
        public let range: Range<String.Index>

        /// Creates a hit.
        public init(reference: TerminalGitHubReference, range: Range<String.Index>) {
            self.reference = reference
            self.range = range
        }
    }

    private let detector: TerminalGitHubReferenceDetector

    /// Creates a scanner.
    ///
    /// - Parameter detector: The detector that decides what a token names.
    public init(detector: TerminalGitHubReferenceDetector = TerminalGitHubReferenceDetector()) {
        self.detector = detector
    }

    /// Every GitHub reference in the text, in the order it appears.
    ///
    /// - Parameters:
    ///   - text: Plain text from one parsed run.
    ///   - repositorySlug: The `owner/name` repository bare references resolve
    ///     against, or `nil` when there is none. A `nil` slug still finds
    ///     references that name their own repository.
    /// - Returns: The hits, in source order, never overlapping.
    public func hits(in text: String, repositorySlug: String?) -> [Hit] {
        var hits: [Hit] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let segment = text[index..<end]

            if let reference = detector.reference(
                inToken: String(segment),
                repositorySlug: repositorySlug
            ),
               // The detector trims wrapping punctuation, so `(#847)` reports
               // `#847`. Locating that inside the segment keeps the brackets
               // out of the link, which is what a reader expects to see
               // underlined. Trimming only removes leading and trailing
               // characters, so the token is always somewhere in here.
               let tokenRange = segment.range(of: reference.rawToken) {
                hits.append(Hit(reference: reference, range: tokenRange))
            }

            index = end
        }

        return hits
    }
}
