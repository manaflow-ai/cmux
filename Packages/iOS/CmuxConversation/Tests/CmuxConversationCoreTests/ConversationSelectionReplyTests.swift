import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationSelectionReplyTests {
    @Test func takesTheSelectedWordsWithoutTheSpaceAroundThem() throws {
        let text = "Deploy the build, then run the tests."
        let range = (text as NSString).range(of: " then run the tests")
        let reply = try #require(ConversationSelectionReply(messageID: "m1", text: text, selectedRange: range))
        #expect(reply.messageID == "m1")
        #expect(reply.text == "then run the tests")
    }

    @Test func countsTheRangeInUTF16LikeATextView() throws {
        // The emoji is two UTF-16 units; the range after it must still land on "fine".
        let text = "👍🏽 looks fine"
        let range = (text as NSString).range(of: "fine")
        let reply = try #require(ConversationSelectionReply(messageID: "m", text: text, selectedRange: range))
        #expect(reply.text == "fine")
    }

    @Test func nothingWorthQuotingIsNoReply() {
        let text = "a   b"
        #expect(ConversationSelectionReply(messageID: "m", text: text, selectedRange: NSRange(location: 1, length: 3)) == nil)
        #expect(ConversationSelectionReply(messageID: "m", text: text, selectedRange: NSRange(location: 0, length: 0)) == nil)
        #expect(ConversationSelectionReply(messageID: "m", text: text, selectedRange: NSRange(location: 3, length: 40)) == nil)
        #expect(ConversationSelectionReply(messageID: "m", text: text, selectedRange: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    /// The Mac's limit: a long selection goes out cut at a word end, with an ellipsis.
    @Test func cutsALongSelectionAtAWordEnd() throws {
        let text = Array(repeating: "word", count: 400).joined(separator: " ")
        let reply = try #require(ConversationSelectionReply(messageID: "m", text: text, selectedRange: NSRange(location: 0, length: (text as NSString).length)))
        #expect(reply.text.count <= ConversationSelectionReply.maxQuoted)
        #expect(reply.text.hasSuffix("word…"))
        let short = try #require(ConversationSelectionReply(messageID: "m", text: "short", selectedRange: NSRange(location: 0, length: 5)))
        #expect(short.text == "short")
    }

    /// The same text as the Mac's `HomeMessageRouting.quoted`.
    @Test func quotesEachLineAsMarkdownThenLeavesALineForTheReply() {
        let reply = ConversationSelectionReply(messageID: "m", text: "first line\n\nthird line")
        #expect(reply.markdownQuote == "> first line\n>\n> third line\n\n")
        #expect(ConversationSelectionReply(messageID: "m", text: "one").markdownQuote == "> one\n\n")
    }
}
