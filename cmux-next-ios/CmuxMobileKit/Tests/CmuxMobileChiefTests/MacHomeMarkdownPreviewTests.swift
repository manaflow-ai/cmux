@testable import CmuxMobileChief
import Testing

/// Lawrence, 2026-11-20 ("this preview thing is not very good"): a preview of a message shows its words, never its
/// Markdown. The Home list row of a Chief that sent a before/after table read "| | Before | After ||---|…".
@Suite("Mac Home preview of Markdown")
struct MacHomeMarkdownPreviewTests {
    @Test("a table is named by its columns")
    func tableIsNamed() {
        let table = "| | Before | After |\n|---|---|---|\n| Light | ![before, light](/tmp/bl.png) | ![after, light](/tmp/al.png) |"
        #expect(plainPreview(table) == "Table: Before / After")
        #expect(plainPreview("Shots below.\n\n" + table) == "Shots below. Table: Before / After")
    }

    @Test("a link shows its label and a picture is left out")
    func linksAndPictures() {
        #expect(plainPreview("See [PR 12](https://github.com/manaflow-ai/cmux/pull/12) ![shot](/tmp/a.png)") == "See PR 12")
        #expect(plainPreview("![before](/tmp/a.png)") == "Image")
        #expect(plainPreview("![before](/tmp/a.png) ![after](/tmp/b.png)") == "2 images")
    }

    @Test("a literal number sign or underscore in a word stays")
    func literalMarksStay() {
        #expect(plainPreview("PR #12 fixes snake_case_names") == "PR #12 fixes snake_case_names")
    }
}
