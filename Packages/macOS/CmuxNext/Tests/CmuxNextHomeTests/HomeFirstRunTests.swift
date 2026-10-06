import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// An empty Chief conversation offers things to do now instead of a pitch
/// (Leo's first-launch capture, op-next-look): one plain line, rows to open
/// a terminal, start an agent or ask the Chief, and a keyboard hint. The
/// ask row fills the field; it never sends. The first message hides the
/// panel.
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

    @Test func theAskRowFillsTheFieldAndNeverSends() throws {
        let (window, view) = Self.view()
        defer { window.close() }
        view.controller.update(items: [], summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let panel = view.firstRun
        #expect(!panel.isHidden)
        #expect(!panel.lead.stringValue.isEmpty)
        #expect(!panel.suggestion.title.isEmpty)
        #expect(view.field.text.isEmpty)
        panel.suggestion.performClick(nil)
        #expect(view.field.text == panel.suggestion.title, "the suggestion fills the field")
        #expect(view.controller.conversationSummary != nil)
        // Never a control that dims to gray when the window is not key.
        #expect(panel.suggestion.label.textColor == panel.terminal.label.textColor)
        #expect(panel.rows.allSatisfy { $0.accessibilityRole() == .button })
    }

    @Test func theTerminalAndAgentRowsAskTheHost() {
        let (window, view) = Self.view()
        defer { window.close() }
        var picked: [HomeFirstRunAction] = []
        view.onFirstRunAction = { picked.append($0) }
        view.firstRun.terminal.performClick(nil)
        view.firstRun.agent.performClick(nil)
        #expect(picked == [.openTerminal, .startAgent])
        #expect(view.field.text.isEmpty, "neither row types into the field")
    }

    @Test func theRowsShowTheirShortcutsAndTheTabHintShowsItsKeys() {
        let (window, view) = Self.view()
        defer { window.close() }
        let panel = view.firstRun
        #expect(panel.hint.isHidden, "no hint until the host passes the keys")
        view.setFirstRunShortcuts(terminal: "⌘T", agent: nil, tabs: "⌃1…9")
        view.controller.update(items: [], summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        #expect(panel.terminal.shortcutLabel.stringValue == "⌘T" && !panel.terminal.shortcutLabel.isHidden)
        #expect(panel.agent.shortcutLabel.isHidden, "an unbound action shows no shortcut")
        #expect(!panel.hint.isHidden && panel.hint.stringValue.contains("⌃1…9"))
        let row = panel.terminal
        #expect(row.label.frame.maxX <= row.shortcutLabel.frame.minX, "label \(row.label.frame) runs into the shortcut")
    }

    @Test func firstRunChromeFollowsTheLiveInterfaceScale() {
        let (window, view) = Self.view()
        defer { window.close() }
        view.controller.update(items: [], summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let panel = view.firstRun
        let baseHeight = panel.terminal.bounds.height
        let baseFontSize = panel.lead.font?.pointSize ?? 0

        view.applyTextScale(1.25)
        view.layoutSubtreeIfNeeded()

        #expect(panel.terminal.bounds.height > baseHeight)
        #expect(panel.lead.font?.pointSize ?? 0 > baseFontSize)
    }

    /// Stability rule: a Chief conversation whose history is still loading
    /// is empty for a moment; the panel waits for the first page instead of
    /// flashing in and out.
    @Test func aHeldPanelWaitsForTheFirstPage() {
        let (window, view) = Self.view()
        defer { window.close() }
        view.holdsFirstRun = true
        view.controller.update(items: [], summary: Self.summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.firstRun.isHidden)
        view.holdsFirstRun = false
        #expect(!view.firstRun.isHidden)
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
