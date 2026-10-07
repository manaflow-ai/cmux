@testable import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// nxdog68-v1 (P1): the Chief tile showed "**strong**" raw. A preview shows
/// an agent's Markdown the way the transcript does (its own parser), and a
/// person's text exactly as typed.
@Suite struct HomePreviewMarkdownTests {
    static func row(author: Participant, text: String) -> InboxRow {
        var row = HomeConversationListTests.row("conv_md", with: [author], at: 1)
        row.summary.lastMessage = Message(id: MessageID("msg_md"), conversation: ConversationID("conv_md"), seq: 1,
                                          clientMessageID: IdempotencyKey("k_md"), author: author.id,
                                          parts: [.text(text, mentions: [])], createdAt: HomeConversationListTests.base)
        row.preview = text
        return row
    }

    @Test func anAgentsMarkdownLosesItsMarkersAndKeepsItsText() {
        let chief = HomeConversationListTests.chief("agent_mux", "Chief")
        let source = "# Plan\n**strong** and *soft*, `code` and [the docs](https://cmux.com)\n- first\n- second"
        let text = Self.row(author: chief, text: source).homePreview(me: HomeConversationListTests.me).text
        for marker in ["**", "`", "](", "# "] { #expect(!text.contains(marker), "\(marker) in \(text)") }
        for word in ["Plan", "strong", "soft", "code", "the docs", "first", "second"] { #expect(text.contains(word), "\(word) lost: \(text)") }
        #expect(!text.contains("\n"))
    }

    @Test func aPersonsTextStaysAsTyped() {
        let austin = HomeConversationListTests.person("user_austin", "Austin")
        #expect(Self.row(author: austin, text: "use **bold** please").homePreview(me: HomeConversationListTests.me).text == "use **bold** please")
    }
}
