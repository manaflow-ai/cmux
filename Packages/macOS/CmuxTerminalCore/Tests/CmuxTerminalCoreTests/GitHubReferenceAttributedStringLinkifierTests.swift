import CmuxTerminalCore
import Foundation
import Testing

@Suite struct GitHubReferenceAttributedStringLinkifierTests {
    private let linkifier = GitHubReferenceAttributedStringLinkifier()
    private let slug = "manaflow-ai/cmux"

    /// Parses markdown the way the sidebar does, then linkifies it.
    private func linkified(
        _ markdown: String,
        slug: String? = "manaflow-ai/cmux"
    ) throws -> AttributedString {
        let parsed = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )
        return linkifier.linkifying(parsed, repositorySlug: slug)
    }

    /// Every linked span paired with where it points, in reading order. This is
    /// the whole observable result: which words became clickable, and to what.
    private func links(_ attributed: AttributedString) -> [(String, String)] {
        attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed[run.range].characters), url.absoluteString)
        }
    }

    @Test
    func aBareReferenceInPlainTextBecomesALink() throws {
        let result = try linkified("landed in #15221 this morning")

        #expect(
            links(result).map(\.0) == ["#15221"]
        )
        #expect(
            links(result).map(\.1) == ["https://github.com/manaflow-ai/cmux/issues/15221"]
        )
    }

    @Test
    func theAuthorsOwnLinkKeepsItsDestination() throws {
        let result = try linkified("see [#15221](https://example.com/elsewhere)")

        #expect(links(result).map(\.1) == ["https://example.com/elsewhere"])
    }

    @Test
    func aCodeSpanIsLeftAsText() throws {
        let result = try linkified("the literal `#15221` is not a reference")

        #expect(links(result).isEmpty)
    }

    @Test
    func linkifyingChangesNoCharacters() throws {
        let markdown = "opened #15221, closed manaflow-ai/cmux#847, see `#1`"
        let parsed = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )
        let result = linkifier.linkifying(parsed, repositorySlug: slug)

        // Height stability is the reason the sidebar can render this inline.
        // Attributes may change; the text may not.
        #expect(String(result.characters) == String(parsed.characters))
    }

    @Test
    func severalReferencesInOneRunEachGetTheirOwnLink() throws {
        let result = try linkified("#847 then #15221 then manaflow-ai/cmux#1")

        #expect(links(result).map(\.0) == ["#847", "#15221", "manaflow-ai/cmux#1"])
    }

    @Test
    func aReferenceAfterStyledTextIsStillLocatedCorrectly() throws {
        // A bold run ahead of the reference means the run carrying it does not
        // start at offset zero, which is where an off-by-one would show.
        let result = try linkified("**shipped** #15221 today")
        let pairs = links(result)

        #expect(pairs.map(\.0) == ["#15221"])
        #expect(pairs.map(\.1) == ["https://github.com/manaflow-ai/cmux/issues/15221"])
    }

    @Test
    func multiScalarCharactersAheadOfAReferenceDoNotShiftIt() throws {
        // A family emoji is one Character made of several scalars. Offsetting
        // by anything other than Characters underlines the wrong span here.
        let result = try linkified("👨‍👩‍👧‍👦 shipped #15221")

        #expect(links(result).map(\.0) == ["#15221"])
    }

    @Test
    func multiScalarCharactersInAnEarlierRunDoNotShiftTheReference() throws {
        // The emoji is inside a bold run, so the reference sits in a later run
        // and its position is measured across a run boundary. Counting that
        // span in scalars rather than Characters moves the underline off the
        // reference; the previous test cannot catch it because everything there
        // is one run.
        let result = try linkified("**👨‍👩‍👧‍👦** shipped #15221")

        #expect(links(result).map(\.0) == ["#15221"])
    }

    @Test
    func aFencedCodeBlockIsLeftAsText() throws {
        // `inlinePresentationIntent` is nil inside a fence, so the code-span
        // rule does not reach here and a block-level check has to.
        let result = try linkified(
            "fixes manaflow-ai/cmux#847\n\n```\ngit log manaflow-ai/cmux#848\n```"
        )

        #expect(links(result).map(\.1) == ["https://github.com/manaflow-ai/cmux/issues/847"])
    }

    @Test
    func aReferenceCutInHalfByStylingIsNotLinked() throws {
        // `manaflow-ai/cmux#84**7**` reaches the scanner as the truncated
        // `manaflow-ai/cmux#84`, which resolves to a different issue than the
        // one on screen. Pointing somewhere the reader was not shown is worse
        // than leaving it plain.
        let result = try linkified("see manaflow-ai/cmux#84**7** please")

        #expect(links(result).isEmpty)
    }

    @Test
    func withNoRepositoryOnlySelfNamingReferencesLink() throws {
        let result = try linkified("#15221 and manaflow-ai/cmux#847", slug: nil)

        #expect(links(result).map(\.0) == ["manaflow-ai/cmux#847"])
    }

    @Test
    func textWithNothingToLinkIsReturnedUnchanged() throws {
        let markdown = "just a plain status line"
        let parsed = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )

        #expect(linkifier.linkifying(parsed, repositorySlug: slug) == parsed)
    }
}
