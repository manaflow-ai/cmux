import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// An empty Chief conversation says what the Chief is and offers one
/// suggested prompt (Leo's dogfood: "an empty pane with an M avatar, a Home
/// label and a Message box"). The suggestion fills the field; it never
/// sends. The first message hides the panel.
@MainActor
@Suite struct HomeFirstRunTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_mux")
    static let id = ConversationID("conv_first_run")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func summary() -> ConversationSummary {
        ConversationSummary(id: id, participants: [Participant(id: me, kind: .human, displayName: "Me"),
                                                   Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)],
                            createdAt: start, updatedAt: start, readCursors: [:])
    }

    static func view() -> (NSWindow, HomeNativeTranscriptView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    @Test func anEmptyChiefConversationExplainsTheChiefAndSuggestsAPrompt() throws {
        let (window, view) = Self.view()
        defer { window.close() }
        view.controller.update(items: [], summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let panel = view.firstRun
        #expect(!panel.isHidden)
        #expect(!panel.title.stringValue.isEmpty)
        #expect(!panel.suggestion.title.isEmpty)
        #expect(view.field.text.isEmpty)
        panel.suggestion.performClick(nil)
        #expect(view.field.text == panel.suggestion.title, "the suggestion fills the field")
        #expect(view.controller.conversationSummary != nil)
        // Text on glass, never a control that dims to gray when the window is not key.
        #expect(panel.suggestion.label.textColor == panel.title.textColor)
        #expect(panel.suggestion.accessibilityRole() == .button)
    }

    @Test func theFirstMessageHidesThePanel() {
        let (window, view) = Self.view()
        defer { window.close() }
        let message = Message(id: MessageID("msg_1"), conversation: Self.id, seq: Seq(1), clientMessageID: IdempotencyKey("k1"),
                              author: Self.chief, parts: [.text("Hello")], createdAt: Self.start)
        let items = CmuxHomeCore.TranscriptWindow(messages: [message]).items(pending: [], me: Self.me)
        view.controller.update(items: items, summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.firstRun.isHidden)
    }
}
