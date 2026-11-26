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
        <iframe>hidden iframe fallback</iframe>
        <div>Visible</div>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("omits descendants hidden by HTML and inline CSS")
    func omitsAttributeAndInlineStyleHiddenDescendants() {
        let parser = HTMLPlainTextParser()
        let html = """
        <span hidden>hidden attribute</span>
        <span style="display: none">hidden display</span>
        <span style="visibility : HIDDEN !important">hidden visibility</span>
        <span>Visible</span>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("visibility visible descendants override a hidden ancestor")
    func preservesVisibilityVisibleDescendants() {
        let parser = HTMLPlainTextParser()
        let html = """
        <span style="visibility: hidden">
        hidden parent
        <span style="visibility: visible">Visible child</span>
        hidden tail
        </span>
        """

        #expect(parser.plainText(from: html) == "Visible child")
    }

    @Test("does not hide text for CSS declaration substring matches")
    func ignoresInlineStyleSubstringFalsePositives() {
        let parser = HTMLPlainTextParser()
        let html = """
        <span data-hidden style="--display:none; display:none-block; visibility:hiddenish">
        Visible
        </span>
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

    @Test(
        "quoted attribute slash does not self-close a raw-text element",
        arguments: [#""https://example.com""#, "'https://example.com'"]
    )
    func omitsScriptWithTrailingSlashAfterQuotedAttribute(
        source: String
    ) {
        let parser = HTMLPlainTextParser()
        let html = """
        <script src=\(source)/>hidden</script>
        <div>Visible</div>
        """

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test(
        "self-closing raw-text elements do not hide later content",
        arguments: ["script", "style", "iframe"]
    )
    func preservesContentAfterSelfClosingRawTextElement(tag: String) {
        let parser = HTMLPlainTextParser()
        let html = "<\(tag)/><template>hidden</template><p>Visible</p>"

        #expect(parser.plainText(from: html) == "Visible")
    }

    @Test("keeps template text hidden when an unquoted attribute ends in slash")
    func omitsTemplateWithTrailingSlashInUnquotedAttribute() {
        let parser = HTMLPlainTextParser()
        let html = """
        <template data-url=https://example.com/>hidden</template>
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

    @Test("raw-text less-than names cannot consume the closing tag")
    func rawTextLessThanNameCannotConsumeClosingTag() {
        let parser = HTMLPlainTextParser()
        let html = """
        <script>if (a<b) { hidden() }</script>
        <template>also hidden</template>
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

    @Test("decodes non-ASCII entities from data input")
    func decodesNonASCIIEntitiesFromData() {
        let parser = HTMLPlainTextParser()
        let html = Data(
            "<p>Caf&eacute; &#8364; &ldquo;quoted&rdquo;</p>".utf8
        )

        #expect(parser.plainText(from: html) == "Café € “quoted”")
    }

    @Test("decodes UTF-16 data with a byte-order mark")
    func decodesUTF16BOMData() throws {
        let parser = HTMLPlainTextParser()
        let html = try #require(
            "<p>日本語 &amp; responsive</p>".data(using: .utf16)
        )

        #expect(parser.plainText(from: html) == "日本語 & responsive")
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

    @Test("rejects excessively nested HTML")
    func rejectsExcessivelyNestedHTML() {
        let parser = HTMLPlainTextParser()
        let depth = 1_024
        let html = String(repeating: "<div>", count: depth)
            + "Visible"
            + String(repeating: "</div>", count: depth)

        #expect(parser.plainText(from: html) == nil)
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
