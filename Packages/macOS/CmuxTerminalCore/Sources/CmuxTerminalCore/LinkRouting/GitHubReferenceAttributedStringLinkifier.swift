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
            // Measured from the start each time rather than accumulated run
            // lengths. Run boundaries are not promised to fall on grapheme
            // cluster boundaries, and one that does not would make the running
            // total drift for every run after it. Blocks reaching here are
            // capped at 4 KB and the result is memoized, so the quadratic walk
            // costs less than the class of bug it removes.
            let runStart = whole.distance(from: whole.startIndex, to: run.range.lowerBound)

            for hit in scanner.hits(in: text, repositorySlug: repositorySlug) {
                // A reference the parser split across runs, such as
                // `owner/repo#84**7**`, reaches here as the truncated `#84`.
                // Linking that points at a different issue than the one the
                // reader sees, which is worse than not linking at all, so a hit
                // touching a run edge with more text pressed against it is
                // dropped.
                guard !isTruncated(hit: hit, in: text, run: run, of: attributed) else { continue }
                let offset = text.distance(from: text.startIndex, to: hit.range.lowerBound)
                let length = text.distance(from: hit.range.lowerBound, to: hit.range.upperBound)
                found.append((runStart + offset, length, hit.reference.url))
            }
        }

        guard !found.isEmpty else { return attributed }

        // Offsets are collected against the unmodified value and applied
        // afterwards. Setting `.link` splits the run it lands in, so reading
        // and writing in one pass would renumber the runs still being walked.
        var linked = attributed
        let total = linked.characters.count
        for hit in found {
            // The two measurements above are taken in different index spaces
            // (one over the whole value, one over a run extracted as a String),
            // and they can disagree if a run boundary ever lands inside a
            // grapheme cluster. `index(_:offsetByCharacters:)` traps rather than
            // returning nil when that pushes it past the end, and this runs on
            // the main actor during a sidebar render, so the bound is checked
            // instead of assumed. Dropping the link is the right failure: the
            // text still renders, it just is not clickable.
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

    /// Whether a hit runs up against a run edge that more text continues past.
    ///
    /// The scanner works on one run's text in isolation, so it cannot see that
    /// the token it matched was cut off by a style change. A reference ending at
    /// the run's last character with a non-whitespace character immediately
    /// after it in the full text was longer than what was matched.
    private func isTruncated(
        hit: GitHubReferenceTextScanner.Hit,
        in text: String,
        run: AttributedString.Runs.Run,
        of attributed: AttributedString
    ) -> Bool {
        if hit.range.lowerBound == text.startIndex,
           run.range.lowerBound > attributed.startIndex {
            let before = attributed.characters.index(before: run.range.lowerBound)
            if !attributed.characters[before].isWhitespace { return true }
        }
        if hit.range.upperBound == text.endIndex,
           run.range.upperBound < attributed.endIndex,
           !attributed.characters[run.range.upperBound].isWhitespace {
            return true
        }
        return false
    }
}
