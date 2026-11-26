import Testing
@testable import MessagesLabHome

/// Up-arrow recall gives an edited message's text as the bubble shows it. MessagesLab's `Edit.text` is the text
/// BEFORE that edit (Engine `.edit` appends the old text), so recall must not read it: after a live edit of
/// "B" to "C", recall offered "B" while the bubble showed "C" (review of the 849eb3f pin roll).
@Suite struct ComposerHistoryEditTests {
    @Test func anEditedMessageIsRecalledAsShown() {
        var m = Message(id: "m1", senderId: "me", sentAt: "2026-10-21T09:00:00-07:00", parts: [.text("C", runs: [])],
                        replyTo: nil, status: nil, edits: [.init(text: "A", at: "2026-10-21T09:00:10-07:00"),
                                                          .init(text: "B", at: "2026-10-21T09:00:20-07:00")],
                        retractedAt: nil, reactions: [])
        m.format = nil
        let state = AppState(conversation: Conversation(id: "c", title: "T", participants: [
            Participant(id: "me", displayName: "Me", isMe: true, avatar: nil)], messages: [m]))
        #expect(ComposerHistory.entries(in: state) == ["C"])
    }
}
