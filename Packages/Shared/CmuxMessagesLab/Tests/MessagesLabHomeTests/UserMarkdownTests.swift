import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

@Suite struct UserMarkdownTests {
    private static let me = ParticipantID("user_me")
    private static let chief = ParticipantID("agent_chief")
    private static let conversation = ConversationID("markdown")
    private static let source = "> quoted prompt\n\n**bold** and *italic* with `code` and [docs](https://example.com)\n\n- one\n- two\n\n```swift\nlet value = 1\n```"

    private static var summary: ConversationSummary {
        ConversationSummary(
            id: conversation,
            title: "Chief",
            participants: [
                CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
            ],
            lastSeq: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            readCursors: [:],
            readCursorTimes: [:])
    }

    @Test func userRowsOptIntoMarkdownWithoutChangingTheirStoredText() {
        let item = TranscriptItem(
            key: IdempotencyKey("pending"), seq: nil, author: me, parts: [.text(source)],
            createdAt: Date(timeIntervalSince1970: 1), delivery: .sending)
        let mapped = HomeMapping.message(item, aliases: [:], me: me, summary: summary)

        #expect(mapped.format == .markdown)
        #expect(mapped.parts.count == 1)
        #expect(mapped.parts.first?.plainText == source)
    }

    @Test func userMarkdownUsesTheQuoteBarLayout() {
        let document = Markdown.parse(Self.source)
        let layout = MarkdownLayoutEngine.layout(document, source: Self.source, maxWidth: 400)

        #expect(document.isRich)
        #expect(document.blocks.contains {
            if case .quote = $0.kind { return true }
            return false
        })
        #expect(layout.boxes.contains {
            if case .quoteBar = $0.kind { return true }
            return false
        })
        #expect(layout.frags.contains { $0.role == .quote })
    }

    @Test func localSendCarriesMarkdownFormatIntoItsImmediateBubble() {
        let conversation = MessagesLabHome.Conversation(
            id: Self.conversation.rawValue,
            title: "Chief",
            participants: [
                MessagesLabHome.Participant(id: Self.me.rawValue, displayName: "Me", isMe: true, avatar: nil),
            ],
            messages: [])
        var state = AppState(conversation: conversation)
        state.ui.draft.text = Self.source

        _ = Reducer.reduce(&state, .send, now: Date(timeIntervalSince1970: 1), newID: { "sent" })

        #expect(state.conversation.messages.last?.format == .markdown)
        #expect(state.conversation.messages.last?.parts.first?.plainText == Self.source)
    }
}
