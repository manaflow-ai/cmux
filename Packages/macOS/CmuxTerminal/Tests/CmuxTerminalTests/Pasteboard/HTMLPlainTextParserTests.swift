import Testing

@testable import CmuxTerminal

@Suite("HTML plain-text parser")
struct HTMLPlainTextParserTests {
    @Test("preserves inline text and decodes entities")
    func preservesInlineTextAndDecodesEntities() {
        #expect(
            HTMLPlainTextParser.plainText(
                from: "<p>Hello <strong>world</strong> &amp; friends &#169;</p>"
            ) == "Hello world & friends ©"
        )
    }

    @Test("omits comments and hidden blocks")
    func omitsCommentsAndHiddenBlocks() {
        let html = """
        <!-- hidden comment -->
        <style>body::before { content: "hidden"; }</style>
        <script>document.write("hidden")</script>
        <template>hidden template</template>
        <noscript>hidden fallback</noscript>
        <div>Visible</div>
        """

        #expect(HTMLPlainTextParser.plainText(from: html) == "Visible")
    }

    @Test("preserves block and line-break boundaries")
    func preservesBlockAndLineBreakBoundaries() {
        let html = """
        <div>first <span>line</span></div>
        <p>second<br>third</p>
        <ul><li>fourth</li><li>fifth</li></ul>
        """

        #expect(
            HTMLPlainTextParser.plainText(from: html)
                == "first line\nsecond\nthird\nfourth\nfifth"
        )
    }

    @Test("image-only HTML has no plain text")
    func imageOnlyHTMLHasNoPlainText() {
        #expect(
            HTMLPlainTextParser.plainText(
                from: "<div><img src=\"capture.png\" alt=\"screenshot\"></div>"
            ) == nil
        )
    }

    @Test("parses from a background task")
    func parsesFromBackgroundTask() async {
        let parsed = await Task.detached {
            HTMLPlainTextParser.plainText(
                from: "<p>remote &amp; responsive</p>"
            )
        }.value

        #expect(parsed == "remote & responsive")
    }
}
