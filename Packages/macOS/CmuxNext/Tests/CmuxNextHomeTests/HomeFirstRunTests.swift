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

/// spec/app-screens.md section 3: clicking empty space in the Home column
/// focuses the message box (R65).
@MainActor
@Suite struct HomeEmptyClickFocusTests {
    @Test func clickingEmptyTranscriptSpaceFocusesTheMessageBox() throws {
        let (window, view) = HomeFirstRunTests.view()
        defer { window.close() }
        view.controller.update(items: [], summary: HomeFirstRunTests.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(nil)
        let point = view.rowHost.convert(CGPoint(x: view.rowHost.bounds.midX, y: 120), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.rowHost.mouseDown(with: event) } else { view.rowHost.mouseUp(with: event) }
        }
        #expect(window.firstResponder === view.field.textView)
    }
}

/// homenat14 snapshot (R65 proof): typed text sat at the field's top-left
/// corner, its first letter clipped, because the glass sized the text view to
/// the whole field. The text starts at the field's insets, where the
/// placeholder is.
@MainActor
@Suite struct HomeFieldTextInsetTests {
    @Test func typedTextStartsAtTheFieldsInsets() {
        let (window, view) = HomeFirstRunTests.view()
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let field = view.field
        field.layoutSubtreeIfNeeded()
        let text = field.textView.convert(field.textView.bounds, to: field)
        #expect(abs(text.minX - field.horizontalInset) <= 0.5, "text view \(text) in field \(field.bounds)")
        #expect(text.maxX <= field.bounds.maxX - field.horizontalInset + 0.5)
    }
}
