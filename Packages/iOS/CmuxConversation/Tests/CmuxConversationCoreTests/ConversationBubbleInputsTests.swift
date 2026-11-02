import Foundation
import Testing
@testable import CmuxConversationCore

/// A live message's bubble text is built off the main thread; the inputs it
/// is built from must equal the transcript row's, or the row misses the
/// bubble text cache and rebuilds on the main thread.
@Suite struct ConversationBubbleInputsTests {
    static func chief(_ markdown: String) -> ConversationMessage {
        let extracted = ConversationMarkdownLinks.extract(markdown)
        return ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "chief", sentAt: Date(),
                                   text: extracted.text, links: extracted.links)
    }

    @Test func liveInputsCarryTheMarkdownLinksAndMatchTheRow() throws {
        let message = Self.chief("see [PR #1](https://github.com/manaflow-ai/cmux/pull/1) and [docs](https://cmux.com/docs)")
        let live = try #require(ConversationBubbleInputs.live(message, meID: "me"))
        #expect(live.links.map(\.url.absoluteString) == ["https://github.com/manaflow-ai/cmux/pull/1", "https://cmux.com/docs"])
        #expect(live.links.map { (message.text as NSString).substring(with: $0.range) } == ["PR #1", "docs"])
        // The transcript row of the same message (incoming, no link card).
        let row = ConversationBubbleInputs(message: message, outgoing: false, meID: "me", linkSplit: nil)
        #expect(live == row)
    }

    @Test func linkCardRebasesLinksOntoTheBubbleAndDropsOnesOutsideIt() throws {
        let card = "https://cmux.com/blog"
        var message = Self.chief("\(card) read [the post](https://cmux.com/p)")
        message.linkPreview = ConversationLinkPreview(url: URL(string: card)!)
        let split = try #require(ConversationLinkSplit.split(text: message.text, preview: message.linkPreview))
        let inputs = ConversationBubbleInputs(message: message, outgoing: false, meID: "me", linkSplit: split)
        #expect(inputs.text == "read the post")
        #expect(inputs.links == [ConversationTextLink(location: 5, length: 8, url: URL(string: "https://cmux.com/p")!)])
        // The pre-build leaves link-card messages to the row.
        #expect(ConversationBubbleInputs.live(message, meID: "me") == nil)
    }

    @Test func plainUnsentAndEmptyMessages() {
        let plain = ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(), text: "hi")
        #expect(ConversationBubbleInputs.live(plain, meID: "me")?.links == [])
        #expect(ConversationBubbleInputs.live(plain, meID: "me")?.outgoing == true)
        var unsent = plain
        unsent.unsentAt = Date()
        #expect(ConversationBubbleInputs.live(unsent, meID: "me") == nil)
        var empty = plain
        empty.text = ""
        #expect(ConversationBubbleInputs.live(empty, meID: "me") == nil)
    }
}
