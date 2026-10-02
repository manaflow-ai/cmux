import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CmuxNextHome

@Suite struct MarkdownFormatterTests {
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    private func render(_ text: String) -> NSAttributedString {
        MarkdownFormatter.attributed(text, fontSize: 13, lineHeight: 18, color: white)
    }

    private func traits(_ string: NSAttributedString, at index: Int) -> CTFontSymbolicTraits {
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        guard let value = string.attribute(key, at: index, effectiveRange: nil) else { return [] }
        // crash-allow: the formatter always sets a CTFont for this key.
        return CTFontGetSymbolicTraits(value as! CTFont)
    }

    @Test func inlineRunsParse() {
        let runs = MarkdownInline.runs("a **b** *c* `d` [e](https://x.dev) \\*f\\*")
        #expect(runs.map(\.text) == ["a ", "b", " ", "c", " ", "d", " ", "e", " *f*"])
        #expect(runs[1].style == .bold)
        #expect(runs[3].style == .italic)
        #expect(runs[5].style == .code)
        #expect(runs[7].style == .underline && runs[7].link == "https://x.dev")
    }

    @Test func unclosedMarkersStayLiteral() {
        #expect(MarkdownInline.runs("2 * 3 = **6").map(\.text).joined() == "2 * 3 = **6")
        #expect(MarkdownInline.runs("snake_case_name").map(\.text).joined() == "snake_case_name")
    }

    @Test func boldIsBoldAndCodeIsMonospaced() {
        let string = render("its reply: **PONG** and `ls`")
        let text = string.string as NSString
        #expect(text as String == "its reply: PONG and ls")
        #expect(traits(string, at: text.range(of: "PONG").location).contains(.traitBold))
        #expect(traits(string, at: text.range(of: "ls").location).contains(.traitMonoSpace))
    }

    @Test func blocksRenderWithoutTheirMarkers() {
        let string = render("# Title\n- one\n2. two\n> quoted\n```\nlet x = 1\n```")
        #expect(string.string == "Title\n•  one\n2.  two\n▎ quoted\nlet x = 1")
        #expect(traits(string, at: 0).contains(.traitBold))
    }

    @Test func malformedFenceDoesNotCrash() {
        #expect(render("```\nunterminated").string == "unterminated")
        #expect(render("``").string == "``")
        #expect(render("[x](").string == "[x](")
    }

    @Test func linksUseTheTextColorNotBlue() {
        let string = render("see [docs](https://cmux.dev)")
        let index = (string.string as NSString).range(of: "docs").location
        let color = string.attribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), at: index,
                                     effectiveRange: nil)
        // crash-allow: the formatter sets a CGColor when a color is given.
        #expect((color as! CGColor) == white)
        #expect(string.attribute(MarkdownFormatter.linkKey, at: index, effectiveRange: nil) as? String == "https://cmux.dev")
    }

    @Test func everyLineKeepsTheFixedHeight() {
        let plain = TextFormatter.measure("a\nb\nc", mentions: [], fontSize: 13, lineHeight: 18, maxWidth: 400)
        let markdown = TextFormatter.measureMarkdown("# a\n`b`\n> c", fontSize: 13, lineHeight: 18, maxWidth: 400)
        #expect(plain.height == markdown.height)
    }
}
