import Foundation
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

    @Test("omits nested template descendants from data input")
    func omitsNestedTemplatesFromData() {
        let parser = HTMLPlainTextParser()
        let html = Data(
            """
            <template>outer <template>inner</template> tail</template>
            <div>Visible</div>
            """.utf8
        )

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("preserves text after a self-closing template")
    func preservesTextAfterSelfClosingTemplate() {
        let parser = HTMLPlainTextParser()

        #expect(
            parser.plainText(from: "<template/>Visible") == "Visible"
        )
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

    @Test("preserves indentation and line breaks in preformatted blocks")
    func preservesPreformattedWhitespace() {
        let parser = HTMLPlainTextParser()
        let html = "<pre>first\n  second\n    third</pre><p>after</p>"

        #expect(
            parser.plainText(from: html)
                == "first\n  second\n    third\nafter"
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

    @Test("rejects HTML larger than the parser input bound")
    func rejectsOversizedInput() {
        let parser = HTMLPlainTextParser()
        let oversizedHTML = String(
            repeating: "x",
            count: HTMLPlainTextParser.maximumInputByteCount + 1
        )

        #expect(parser.plainText(from: oversizedHTML) == nil)
        #expect(parser.plainText(from: Data(oversizedHTML.utf8)) == nil)
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
