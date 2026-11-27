@testable import CmuxNextPages
import Testing

/// A viewer quote's card title and the chat text it sends (viewer-comments-DESIGN.md).
struct ChatQuoteTests {
    @Test func titleNamesTheFileAndLineRange() {
        #expect(ChatQuote(source: "/repo/docs/README.md", kind: .markdown, lines: 12...18, quoted: "x").title == "README.md · L12–18")
        #expect(ChatQuote(source: "/repo/a.swift", kind: .code, lines: 7...7, quoted: "x").title == "a.swift · L7")
        #expect(ChatQuote(source: "/repo/a.swift", kind: .code, quoted: "x").title == "a.swift")
    }

    @Test func aWebSourceKeepsItsHostAndPath() {
        #expect(ChatQuote(source: "https://example.com/docs/page?x=1", kind: .web, quoted: "x").title == "example.com/docs/page")
    }

    @Test func markdownQuotesEveryLineThenTheComment() {
        let quote = ChatQuote(source: "/repo/README.md", kind: .markdown, lines: 3...4,
                              quoted: "first line\nsecond line\n", comment: "Is this right?")
        #expect(quote.markdown == "> **README.md · L3–4**\n> first line\n> second line\n\nIs this right?")
    }

    @Test func markdownWithNoCommentIsTheQuoteAlone() {
        let quote = ChatQuote(source: "/repo/README.md", kind: .markdown, lines: 1...1, quoted: "hello", comment: "  \n")
        #expect(quote.markdown == "> **README.md · L1**\n> hello")
    }

    @Test func blankLinesInsideTheQuoteStayInTheQuote() {
        let quote = ChatQuote(source: "/r/a.md", kind: .markdown, lines: 1...3, quoted: "a\n\n> b", comment: "c")
        #expect(quote.markdown == "> **a.md · L1–3**\n> a\n>\n> > b\n\nc")
    }
}
