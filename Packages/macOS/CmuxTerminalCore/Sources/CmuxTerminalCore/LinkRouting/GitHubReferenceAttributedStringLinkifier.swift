public import Foundation

/// Turns the GitHub references inside already-parsed markdown into links.
///
/// Markdown gives a link to text an author marked up as one. Agents writing
/// into a sidebar metadata block, a commit message or a status line write
/// `manaflow-ai/cmux#15221`, not `[#15221](https://...)`, and today that arrives
/// as plain text with nothing to click. This walks the parsed result and
/// attaches the URL that ``GitHubReferenceTextScanner`` resolves for each
/// reference.
///
/// It runs after the parser, never before it. Scanning the markdown source
/// would mean deciding for itself what is a code span, what is inside a fenced
/// block and what is already a link, which is the parser's job and which it
/// would get wrong. Working on runs means the parser has already made those
/// calls, so what is left is to skip the runs it marked and to notice when a
/// style change has cut a reference in half.
public struct GitHubReferenceAttributedStringLinkifier: Sendable {
    private let scanner: GitHubReferenceTextScanner

    public init(scanner: GitHubReferenceTextScanner = GitHubReferenceTextScanner()) {
        self.scanner = scanner
    }

    /// The same text with a `.link` on every GitHub reference that did not
    /// already carry one.
    ///
    /// - Parameters:
    ///   - attributed: Parsed markdown. Characters are never changed, only
    ///     attributes, so measured heights are unaffected.
    ///   - repositorySlug: The `owner/name` a bare `#123` belongs to. `nil`
    ///     means only references that name their own repository are linked.
    public func linkifying(
        _ attributed: AttributedString,
        repositorySlug: String?
    ) -> AttributedString {
        var found: [(offset: Int, length: Int, url: URL)] = []
        let whole = attributed.characters

        for run in attributed.runs {
            // An author's own link wins. Re-pointing `[#1](https://elsewhere)`
            // at GitHub would silently send the reader somewhere they were not
            // told about.
            guard run.link == nil else { continue }
            // A backtick span is text being shown, not a reference being made.
            guard run.inlinePresentationIntent?.contains(.code) != true else { continue }
            // And the block-level equivalent. `inlinePresentationIntent` is nil
            // inside a fenced block, so the inline check above does not cover
            // it, and a fence full of sample commands would otherwise come out
            // studded with links.
            guard !isCodeBlock(run.presentationIntent) else { continue }

            let text = String(attributed[run.range].characters)

            for hit in scanner.hits(in: text, repositorySlug: repositorySlug) {
                // The scanner measures inside the run extracted as its own
                // String, which is not the whole value's index space: a run
                // boundary is not promised to fall on a grapheme cluster
                // boundary, so the two can disagree about how many Characters a
                // span holds. The hit is walked back into the whole value once,
                // here, and everything after this point is measured there.
                // Bounding the walk by the run means a disagreement drops the
                // link rather than moving it onto the wrong words.
                let leading = text.distance(from: text.startIndex, to: hit.range.lowerBound)
                let matched = text.distance(from: hit.range.lowerBound, to: hit.range.upperBound)
                guard
                    let start = whole.index(
                        run.range.lowerBound,
                        offsetBy: leading,
                        limitedBy: run.range.upperBound
                    ),
                    let end = whole.index(
                        start,
                        offsetBy: matched,
                        limitedBy: run.range.upperBound
                    )
                else { continue }
                guard
                    !isTruncated(
                        hit: hit,
                        at: start..<end,
                        of: attributed,
                        repositorySlug: repositorySlug
                    )
                else { continue }
                found.append(
                    (
                        whole.distance(from: whole.startIndex, to: start),
                        whole.distance(from: start, to: end),
                        hit.reference.url
                    )
                )
            }
        }

        guard !found.isEmpty else { return attributed }

        // Offsets are collected against the unmodified value and applied
        // afterwards. Setting `.link` splits the run it lands in, so reading
        // and writing in one pass would renumber the runs still being walked.
        var linked = attributed
        let total = linked.characters.count
        for hit in found {
            // Both numbers were measured over the whole value's characters and
            // `linked` still holds those same characters, so this stays in
            // range. `index(_:offsetByCharacters:)` traps rather than returning
            // nil if it ever did not, and this runs on the main actor during a
            // sidebar render, so the bound is checked instead of assumed.
            guard hit.offset >= 0, hit.length > 0, hit.offset + hit.length <= total else { continue }
            let start = linked.index(linked.startIndex, offsetByCharacters: hit.offset)
            let end = linked.index(start, offsetByCharacters: hit.length)
            linked[start..<end].link = hit.url
        }
        return linked
    }

    /// Whether a run sits inside a fenced or indented code block.
    private func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        guard let intent else { return false }
        return intent.components.contains { component in
            if case .codeBlock = component.kind { return true }
            return false
        }
    }

    /// Whether the parser cut this reference out of a longer token.
    ///
    /// The scanner reads one run at a time, so a style change inside a reference
    /// hands it a fragment that parses on its own: `owner/repo#84**7**` arrives
    /// as `owner/repo#84`, which resolves to a different issue than the one on
    /// screen.
    ///
    /// Asking whether text is pressed against the run's edge cannot tell that
    /// apart from ordinary punctuation. `**owner/repo#847**.` also has a
    /// non-whitespace character on the far side of the edge and is not cut at
    /// all, and a token whose trailing punctuation the detector trims, as in
    /// `owner/repo#84.**7**`, does not reach the edge even though it is cut.
    ///
    /// So the question is put to the text the reader sees. Take the whole
    /// whitespace-delimited token the hit sits in, across every run it spans,
    /// and scan that: a reference that survived styling resolves to the same
    /// thing, and one the parser cut resolves to something else or to nothing.
    private func isTruncated(
        hit: GitHubReferenceTextScanner.Hit,
        at range: Range<AttributedString.Index>,
        of attributed: AttributedString,
        repositorySlug: String?
    ) -> Bool {
        let characters = attributed.characters
        var start = range.lowerBound
        while start > characters.startIndex {
            let previous = characters.index(before: start)
            guard !characters[previous].isWhitespace else { break }
            start = previous
        }
        var end = range.upperBound
        while end < characters.endIndex, !characters[end].isWhitespace {
            end = characters.index(after: end)
        }

        let token = String(characters[start..<end])
        // One token holds at most one hit, since the scanner splits on the
        // whitespace this token has none of.
        guard let rescanned = scanner.hits(in: token, repositorySlug: repositorySlug).first else {
            return true
        }
        return rescanned.reference != hit.reference
    }
}
