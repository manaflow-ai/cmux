import Testing

@testable import CmuxTerminal

@Suite("HTML plain-text parser")
struct HTMLPlainTextParserTests {
    @Test("preserves inline text and decodes entities")
    func preservesInlineTextAndDecodesEntities() {
        let parser = HTMLPlainTextParser()
        #expect(
            parser.plainText(
                from: "<p>Hello <strong>world</strong> &amp; friends &#169;</p>"
            ) == "Hello world & friends ©"
        )
    }

    @Test("omits comments and hidden blocks")
    func omitsCommentsAndHiddenBlocks() {
        let parser = HTMLPlainTextParser()
        let html = """
        <!-- hidden comment -->
        <style>body::before { content: "hidden"; }</style>
        <script>document.write("hidden")</script>
        <template>hidden template</template>
        <noscript>hidden fallback</noscript>
        <div>Visible</div>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("does not mistake an attribute URL slash for a self-closing script")
    func omitsScriptWithTrailingSlashInUnquotedAttribute() {
        let parser = HTMLPlainTextParser()
        let html = """
        <script src=http://example.com/>hidden</script>
        <div>Visible</div>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("preserves visible text around malformed angle brackets")
    func preservesVisibleTextAroundMalformedAngleBrackets() {
        let parser = HTMLPlainTextParser()
        #expect(
            parser.plainText(
                from: "<p>2 < 3 and 5 > 4</p><p>Still visible</p>"
            ) == "2 < 3 and 5 > 4\nStill visible"
        )
    }

    @Test("script source text cannot consume the closing tag")
    func scriptSourceTextCannotConsumeClosingTag() {
        let parser = HTMLPlainTextParser()
        let html = """
        <script>if (value < "quoted") { hidden() }</script>
        <p>Visible</p>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("decodes common non-ASCII named entities")
    func decodesCommonNonASCIINamedEntities() {
        let parser = HTMLPlainTextParser()
        #expect(
            parser.plainText(
                from: "<p>Caf&eacute; &euro; &ldquo;quoted&rdquo;</p>"
            ) == "Café € “quoted”"
        )
    }

    @Test("preserves block and line-break boundaries")
    func preservesBlockAndLineBreakBoundaries() {
        let parser = HTMLPlainTextParser()
        let html = """
        <div>first <span>line</span></div>
        <p>second<br>third</p>
        <ul><li>fourth</li><li>fifth</li></ul>
        """

        #expect(
            parser.plainText(from: html)
                == "first line\nsecond\nthird\nfourth\nfifth"
        )
    }

    @Test("image-only HTML has no plain text")
    func imageOnlyHTMLHasNoPlainText() {
        let parser = HTMLPlainTextParser()
        #expect(
            parser.plainText(
                from: "<div><img src=\"capture.png\" alt=\"screenshot\"></div>"
            ) == nil
        )
    }

    @Test("parses from a background task")
    func parsesFromBackgroundTask() async {
        let parsed = await Task.detached {
            HTMLPlainTextParser().plainText(
                from: "<p>remote &amp; responsive</p>"
            )
        }.value

        #expect(parsed == "remote & responsive")
    }
}
