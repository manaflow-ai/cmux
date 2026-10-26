import Foundation
import Testing
@testable import CmuxConversationCore

/// A live message's bubble text is built off the main thread from these
/// inputs; they must match the transcript row's, or the row misses the
/// bubble text cache and rebuilds on the main thread.
@Suite struct ConversationLiveBubbleTextTests {
    @Test func carriesTheMessagesMarkdownLinksSoTheRowHitsTheCache() throws {
        let extracted = ConversationMarkdownLinks.extract("see [PR #1](https://github.com/manaflow-ai/cmux/pull/1) and [docs](https://cmux.com/docs)")
        let message = ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "chief", sentAt: Date(),
                                          text: extracted.text, links: extracted.links)
        let live = try #require(ConversationLiveBubbleText(message: message, meID: "me"))
        // What the transcript row builds its text from (no link card here).
        let row = ConversationTextLink.bubbleLinks(message.links, bodyLength: message.text.utf16.count)
        #expect(row.count == 2)
        #expect(live.links == row)
    }

    @Test func plainMessageHasNoLinksAndSkipsCardsPollsAndUnsent() {
        let plain = ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(), text: "hi")
        #expect(ConversationLiveBubbleText(message: plain, meID: "me")?.links == [])
        #expect(ConversationLiveBubbleText(message: plain, meID: "me")?.outgoing == true)
        var unsent = plain
        unsent.unsentAt = Date()
        #expect(ConversationLiveBubbleText(message: unsent, meID: "me") == nil)
    }
}
