import CmuxTerminalCore
import Foundation
import Testing

@Suite struct GitHubReferenceTextScannerTests {
    private let scanner = GitHubReferenceTextScanner()
    private let slug = "manaflow-ai/cmux"

    /// The matched text and the URL for each hit, which is what a renderer
    /// needs and all a test should pin.
    private func scan(_ text: String, slug: String? = "manaflow-ai/cmux") -> [(String, String)] {
        scanner.hits(in: text, repositorySlug: slug).map {
            (String(text[$0.range]), $0.reference.url.absoluteString)
        }
    }

    @Test func everyShapeInASentenceIsFound() {
        let hits = scan("Fixes #847, see manaflow-ai/cmux#13742 and commit 73396e6.")
        #expect(hits.map(\.0) == ["#847", "manaflow-ai/cmux#13742", "73396e6"])
        #expect(hits.map(\.1) == [
            "https://github.com/manaflow-ai/cmux/issues/847",
            "https://github.com/manaflow-ai/cmux/issues/13742",
            "https://github.com/manaflow-ai/cmux/commit/73396e6"
        ])
    }

    @Test func wrappingPunctuationStaysOutsideTheLink() {
        // A reader expects the brackets and the full stop to stay plain text.
        #expect(scan("(#847)").map(\.0) == ["#847"])
        #expect(scan("see #847.").map(\.0) == ["#847"])
        #expect(scan("\"#847\"").map(\.0) == ["#847"])
    }

    @Test func hitsAreInSourceOrderAndDoNotOverlap() {
        // Mixed widths and wrapping punctuation, so ordering is carried by the
        // ranges rather than by every hit being the same shape. The lengths
        // differ and one is bracketed, which is where a range built against the
        // segment instead of the whole text would show up out of order.
        let text = "(#333) then manaflow-ai/cmux#1 then #22."
        let hits = scanner.hits(in: text, repositorySlug: slug)
        #expect(hits.map { String(text[$0.range]) } == ["#333", "manaflow-ai/cmux#1", "#22"])
        for (earlier, later) in zip(hits, hits.dropFirst()) {
            #expect(earlier.range.upperBound <= later.range.lowerBound)
        }
    }

    @Test func referencesRunTogetherWithoutASpaceYieldNothing() {
        // The documented limit of the one-token-per-segment model: the combined
        // segment parses as neither reference, so nothing is linked rather than
        // one of the two being picked arbitrarily. A click on the same
        // characters does nothing either, which is the point.
        #expect(scan("see #847;#848").isEmpty)
        #expect(scan("see #847/#848").isEmpty)
        #expect(scan("see #847's status").isEmpty)
        // Separated by a space, both are found, so this is about the segment
        // boundary and not about the numbers.
        #expect(scan("see #847 #848").map(\.0) == ["#847", "#848"])
    }

    @Test func textWithNothingToLinkYieldsNothing() {
        #expect(scan("ordinary prose about issue 847 and nothing else").isEmpty)
        #expect(scan("").isEmpty)
        #expect(scan("   \n\t  ").isEmpty)
    }

    @Test func aMissingRepositoryStillFindsSelfNamingReferences() {
        let hits = scan("Fixes #847, see manaflow-ai/cmux#13742, commit 73396e6.", slug: nil)
        #expect(hits.map(\.0) == ["manaflow-ai/cmux#13742"])
    }

    @Test func urlsAreLeftAloneForTheParserToHandle() {
        // A markdown parser has already turned these into links, and a scanner
        // that reached inside one would link the fragment instead.
        #expect(scan("https://github.com/manaflow-ai/cmux/pull/15221#issuecomment-1").isEmpty)
    }

    @Test func rangesAddressTheOriginalText() {
        // The ranges have to be usable against the string that was passed in,
        // not against a copy the scanner made, or a renderer would attribute
        // the wrong characters.
        let text = "before #847 after"
        guard let hit = scanner.hits(in: text, repositorySlug: slug).first else {
            Issue.record("expected a hit")
            return
        }
        #expect(text[hit.range] == "#847")
        var edited = text
        edited.replaceSubrange(hit.range, with: "LINK")
        #expect(edited == "before LINK after")
    }

    @Test func multilineTextIsScannedAcrossItsLines() {
        let hits = scan("first line #1\nsecond line #2\n")
        #expect(hits.map(\.0) == ["#1", "#2"])
    }
}
