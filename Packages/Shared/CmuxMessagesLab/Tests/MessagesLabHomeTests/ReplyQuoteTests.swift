import Foundation
import Testing
@testable import MessagesLabHome

/// Reply to Selection's quote rules (ReplyQuote.swift): one source message, the blockquote it
/// goes out as and reads back from, the shown excerpt, and finding its words in the original.
@Suite struct ReplyQuoteTests {
    @Test func aSelectionInOneMessageIsAQuote() throws {
        let q = try #require(ReplyQuote(selection: [("part:m1:0", NSRange(location: 4, length: 5), "  cmux22 \n")], messageId: "m1", partIndex: 0))
        #expect(q.text == "cmux22")
        #expect(q.source == PartRef(messageId: "m1", partIndex: 0))
        #expect(q.range == NSRange(location: 4, length: 5))
    }

    @Test func aSelectionReachingAnotherMessageIsNoQuote() {
        #expect(ReplyQuote(selection: [("part:m1:0", NSRange(location: 0, length: 3), "abc"),
                                       ("part:m2:0", NSRange(location: 0, length: 3), "def")], messageId: "m1", partIndex: 0) == nil)
        #expect(ReplyQuote(selection: [("part:m1:0", NSRange(location: 0, length: 2), " \n")], messageId: "m1", partIndex: 0) == nil)
        #expect(ReplyQuote(selection: [], messageId: "m1", partIndex: 0) == nil)
    }

    @Test(arguments: [
        ("one line", "Why?", "> one line\n\nWhy?"),
        ("two\nlines", "ok", "> two\n> lines\n\nok"),
        ("a\n\nb", "x", "> a\n>\n> b\n\nx"),
    ])
    func theQuoteGoesOutAsABlockquoteAndReadsBack(quote: String, reply: String, wire: String) throws {
        let q = try #require(ReplyQuote(selection: [("part:m:0", NSRange(location: 0, length: 1), quote)], messageId: "m", partIndex: 0))
        #expect(q.quoted(reply: reply) == wire)
        let back = try #require(ReplyQuote.split(wire))
        #expect(back.quote == quote)
        #expect(back.body == reply)
    }

    @Test func textWithoutALeadingQuoteIsNotSplit() {
        #expect(ReplyQuote.split("no quote > here") == nil)
        #expect(ReplyQuote.split(">") == nil)
        #expect(ReplyQuote.split("> only a quote")?.body == "")
    }

    @Test func aLongQuoteIsCutAtAWordWithAnEllipsis() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let e = ReplyQuote.excerpt(long, limit: 40)
        #expect(e.hasSuffix("…"))
        #expect(e.count <= 40)
        #expect(!e.dropLast().hasSuffix(" "))
        #expect(ReplyQuote.excerpt("a\n  b\tc", limit: 40) == "a b c")
    }

    @Test func theBubbleHeadIsTheQuotedExcerptStyledQuote() {
        let (head, run) = ReplyQuote.head("cmux22")
        #expect(head == "\u{201C}cmux22\u{201D}")
        #expect(run.start == 0 && run.length == (head as NSString).length && run.style == ["quote"])
    }

    @Test func theQuotesWordsAreFoundInTheOriginal() throws {
        let original = "I moved the nightly off Blacksmith. The NEXT build now runs\non cmux22, and classic stays."
        let exact = try #require(ReplyQuote.locate("NEXT build", in: original))
        #expect((original as NSString).substring(with: exact) == "NEXT build")
        // Reflowed: the quote's space is a line break in the original.
        let reflowed = try #require(ReplyQuote.locate("runs on cmux22", in: original))
        #expect((original as NSString).substring(with: reflowed) == "runs\non cmux22")
        // Cut: the words before the ellipsis.
        let cut = try #require(ReplyQuote.locate("The NEXT build now…", in: original))
        #expect((original as NSString).substring(with: cut) == "The NEXT build now")
        #expect(ReplyQuote.locate("not in it", in: original) == nil)
    }
}
