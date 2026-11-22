import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): the vendored Markdown parser and
/// layout read agent text (external input) by scalar index. Seeded random documents built
/// from the syntax that drives those indices (emphasis runs, brackets, entities, autolinks,
/// link definitions, ragged tables, deep nesting) never trap, and the spans stay inside
/// their text.
@Suite struct MarkdownParserFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        mutating func below(_ n: Int) -> Int { Int(truncatingIfNeeded: next() % UInt64(max(n, 1))) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    static let tokens = [
        "*", "**", "***", "_", "__", "~~", "~", "`", "``", "```", "\\", "\\*", "[", "]", "![", "](", ")", "(", "<", ">", "&", "&amp;",
        "&#x1F600;", "&#99999999;", "&;", "&nbsp", "www.", "http://", "https://a.b/c?d=(e)", "x@y.co", "@", "mailto:", "[a]: /u \"t\"\n",
        "[a]", "[a][]", "[a][b]", "| a | b |\n", "|---|:-:|\n", "| c |\n", "| d | e | f | g |\n", "- ", "* ", "1. ", "12345678901. ",
        "> ", ">> ", "    ", "\t", "\n", "\n\n", "\r\n", "\r", "# ", "###### ", "####### ", "---\n", "===\n", "- [ ] ", "- [x] ",
        "word", "a.b", "e\u{301}", "👩‍👩‍👧‍👦", "日本語", "שלום", "\u{200D}", " ", "  \n", String(repeating: "x", count: 120),
    ]

    static func document(_ rng: inout Rng, max: Int = 60) -> String {
        (0..<rng.below(max)).map { _ in rng.pick(tokens) }.joined()
    }

    @Test func randomDocumentsParseAndLayOutAtAnyWidth() {
        var rng = Rng(state: 0x5EED_CAFE)
        for _ in 0..<2_000 {
            let text = Self.document(&rng)
            let doc = Markdown.parse(text)
            let width = CGFloat(rng.pick([1, 20, 80, 200, 420, 900]))
            let layout = MarkdownLayoutEngine.layout(doc, source: text, maxWidth: width, tableColumns: rng.below(3) == 0 ? [10, 400] : nil,
                                                     fill: rng.below(2) == 0)
            let plain = (layout.plain as NSString).length
            _ = layout.offset(at: CGPoint(x: CGFloat(rng.below(900)), y: CGFloat(rng.below(600))))
            _ = layout.link(at: CGPoint(x: CGFloat(rng.below(900)), y: CGFloat(rng.below(600))))
            _ = layout.selectionRects(NSRange(location: rng.below(plain + 4), length: rng.below(plain + 4)), visible: 0...CGFloat(rng.below(2_000)))
        }
    }

    @Test func inlineSpansStayInsideTheirText() {
        var rng = Rng(state: 77)
        for _ in 0..<4_000 {
            let source = Self.document(&rng, max: 30)
            let t = MDInlineParser.parse(source, breaks: rng.below(2) == 0)
            let length = (t.string as NSString).length
            for span in t.spans { #expect(span.location >= 0 && span.length >= 0 && span.location + span.length <= length, "\(span) outside \(length)") }
            _ = MDInlineParser.unescape(source)
            _ = MarkdownLinkPolicy.url(source)
        }
    }

    @Test func deepNestingStaysLiteralWithoutTrapping() {
        let deep = String(repeating: "> - ", count: 80) + "**x" + String(repeating: "[", count: 300) + "_y_" + String(repeating: "]", count: 300)
        let doc = Markdown.parse(deep)
        _ = MarkdownLayoutEngine.layout(doc, source: deep, maxWidth: 300)
    }
}
