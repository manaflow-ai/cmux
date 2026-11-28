import Testing

@testable import CmuxAgentChatUI

@Suite("ChatTextBlockParser")
struct ChatTextBlockParserTests {
    private let parser = ChatTextBlockParser()

    @Test("headings parse with their level and stripped text")
    func headings() {
        let blocks = parser.blocks(from: "# Title\n## Sub\n### Small")
        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .heading(level: 1))
        #expect(blocks[0].text == "Title")
        #expect(blocks[1].kind == .heading(level: 2))
        #expect(blocks[2].kind == .heading(level: 3))
    }

    @Test("a bare hash without a space is a paragraph, not a heading")
    func notAHeading() {
        let blocks = parser.blocks(from: "#hashtag not a heading")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test("bullet and ordered list items parse with markers and indent")
    func lists() {
        let blocks = parser.blocks(from: "- first\n- second\n1. one\n2) two\n  - nested")
        #expect(blocks[0].kind == .bullet(indent: 0))
        #expect(blocks[0].text == "first")
        #expect(blocks[2].kind == .ordered(marker: "1.", indent: 0))
        #expect(blocks[3].kind == .ordered(marker: "2)", indent: 0))
        #expect(blocks[4].kind == .bullet(indent: 1))
        #expect(blocks[4].text == "nested")
    }

    @Test("block quotes strip the marker")
    func quotes() {
        let blocks = parser.blocks(from: "> quoted line")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .quote)
        #expect(blocks[0].text == "quoted line")
    }

    @Test("consecutive plain lines coalesce; a blank line splits paragraphs")
    func paragraphs() {
        let blocks = parser.blocks(from: "line one\nline two\n\nsecond para")
        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].text == "line one\nline two")
        #expect(blocks[1].text == "second para")
    }

    @Test("a mixed message keeps heading, paragraph, and list as separate blocks")
    func mixed() {
        let blocks = parser.blocks(from: "## Plan\nDo the thing.\n- step a\n- step b")
        #expect(blocks.map(\.kind) == [
            .heading(level: 2), .paragraph, .bullet(indent: 0), .bullet(indent: 0),
        ])
    }

    @Test("blank input yields no blocks")
    func blank() {
        #expect(parser.blocks(from: "   \n\n").isEmpty)
    }

    @Test("seven or more hashes is not a heading")
    func tooManyHashes() {
        let blocks = parser.blocks(from: "####### not a heading")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test("a decimal like 1.5 is not an ordered list item")
    func decimalNotOrdered() {
        let blocks = parser.blocks(from: "1.5 release notes")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test("horizontal rules parse, including spaced and other markers")
    func horizontalRules() {
        for rule in ["---", "***", "___", "- - -", "* * *", "-----"] {
            let blocks = parser.blocks(from: rule)
            #expect(blocks.count == 1, "\(rule) should be one block")
            #expect(blocks[0].kind == .rule, "\(rule) should be a rule, got \(blocks[0].kind)")
        }
    }

    @Test("a rule separates surrounding paragraphs into distinct blocks")
    func ruleSeparates() {
        let blocks = parser.blocks(from: "before\n---\nafter")
        #expect(blocks.map(\.kind) == [.paragraph, .rule, .paragraph])
    }

    @Test("two dashes is not a rule")
    func twoDashesNotRule() {
        let blocks = parser.blocks(from: "-- not a rule")
        #expect(blocks[0].kind == .paragraph)
    }

    @Test("a hyphen without a trailing space is not a bullet")
    func hyphenWord() {
        let blocks = parser.blocks(from: "-rf is a flag, not a bullet")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }
}
