import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Up and Down in Home's message box recall the person's sent messages like a
/// shell's history (Lawrence 2026-10-19: "Up arrow. You need to do work
/// properly. We need to handle unfocus as well so that, like it is history").
/// Drives a real `ChatController` over a loaded conversation in an offscreen
/// window, with real arrow key-downs into the field.
@MainActor @Suite(.serialized) struct ComposerHistoryKeysTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    @MainActor struct Pane {
        let window: NSWindow
        let controller: ChatController
        var field: FieldTextView { controller.demo!.compose.textView.view }
        var host: HostView { controller.host }
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    /// The person's messages, oldest first (the Chief answers between them).
    static let sent = ["first ask", "second ask", "third ask"]

    /// The conversation: the Chief, then each of ``sent`` followed by a Chief reply.
    private func pane() -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var texts: [(ParticipantID, String)] = [(Self.them, "Hi, what can I do?")]
        for (i, s) in Self.sent.enumerated() { texts += [(Self.me, s), (Self.them, "Reply \(i)")] }
        let items = texts.enumerated().map { i, t in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i + 1), author: t.0, parts: [.text(t.1)],
                           createdAt: base.addingTimeInterval(Double(i)), delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_history"), title: "Chief", participants: people,
                                          lastSeq: Seq(items.count), createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_history"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        return Pane(window: window, controller: controller)
    }

    /// A plain arrow key-down as AppKit makes it (function and keypad flags).
    private func arrow(up: Bool, in p: Pane) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber, context: nil,
                         characters: up ? "\u{F700}" : "\u{F701}", charactersIgnoringModifiers: up ? "\u{F700}" : "\u{F701}",
                         isARepeat: false, keyCode: up ? 126 : 125)!
    }

    private func press(up: Bool, in p: Pane) { p.field.keyDown(with: arrow(up: up, in: p)) }

    private func type(_ text: String, in p: Pane) {
        p.window.makeFirstResponder(p.field)
        p.field.insertText(text, replacementRange: p.field.selectedRange())
    }

    @Test func upInAnEmptyBoxRecallsTheNewestThenOlderSentMessages() {
        let p = pane()
        p.window.makeFirstResponder(p.field)

        press(up: true, in: p)
        #expect(p.field.string == "third ask")
        #expect(p.controller.store?.state.ui.draft.text == "third ask", "the draft follows the recalled text")
        press(up: true, in: p)
        #expect(p.field.string == "second ask")
        press(up: true, in: p)
        #expect(p.field.string == "first ask")
        // Past the oldest: it stays.
        press(up: true, in: p)
        #expect(p.field.string == "first ask")
        #expect(p.field.selectedRange() == NSRange(location: ("first ask" as NSString).length, length: 0))
    }

    @Test func downStepsNewerAndGivesTheTypedDraftBack() {
        let p = pane()
        type("half typed", in: p)

        press(up: true, in: p)
        press(up: true, in: p)
        #expect(p.field.string == "second ask")
        press(up: false, in: p)
        #expect(p.field.string == "third ask")
        press(up: false, in: p)
        #expect(p.field.string == "half typed")
        // No browse now: Down leaves the draft alone.
        press(up: false, in: p)
        #expect(p.field.string == "half typed")
    }

    /// In a multi-line draft the arrows move the caret; Up recalls only from the first line.
    @Test func aMultiLineDraftKeepsItsCaretArrows() {
        let p = pane()
        type("line one\nline two", in: p)
        let draft = p.field.string

        press(up: true, in: p)
        #expect(p.field.string == draft, "Up on the last line moved into the history")
        #expect(p.field.selectedRange().location < ("line one\n" as NSString).length, "the caret went up a line")

        press(up: true, in: p)
        #expect(p.field.string == "third ask", "Up on the first line recalls")
        press(up: false, in: p)
        #expect(p.field.string == draft, "Down gives the multi-line draft back")
    }

    /// An edit to a recalled message makes it the draft: Down no longer swaps it away.
    @Test func editingARecalledMessageEndsTheBrowse() {
        let p = pane()
        p.window.makeFirstResponder(p.field)
        press(up: true, in: p)
        p.field.insertText(" again", replacementRange: p.field.selectedRange())
        #expect(p.field.string == "third ask again")

        press(up: false, in: p)
        #expect(p.field.string == "third ask again")
    }

    /// The history is the conversation's own messages: a new controller over
    /// the same transcript (an app relaunch) recalls them too.
    @Test func theHistoryOutlivesTheController() {
        var p: Pane? = pane()
        p?.window.makeFirstResponder(p?.field)
        p = nil
        let again = pane()
        again.window.makeFirstResponder(again.field)
        press(up: true, in: again)
        #expect(again.field.string == "third ask")
    }
    // MARK: Unfocused: Home has the keyboard, the box does not

    /// After a click on the transcript, a pane-focus shortcut (no responder),
    /// or a window switch: Up puts the keyboard in the box and recalls.
    @Test(arguments: ["transcript", "nothing", "pane"])
    func upFromOutsideTheBoxFocusesItAndRecalls(from place: String) {
        let p = pane()
        type("kept draft", in: p)
        switch place {
        case "transcript":
            p.host.scrollView.document.takesFocus = true
            p.window.makeFirstResponder(p.host.scrollView.document)
            p.host.scrollView.document.takesFocus = false
        case "pane": p.window.makeFirstResponder(p.host)
        default: p.window.makeFirstResponder(nil)
        }
        let responder = p.window.firstResponder
        #expect(responder !== p.field)
        #expect(p.controller.historyTakesArrowKeys(from: responder))

        #expect(p.controller.recallHistoryFromOutside(.older))
        #expect(p.window.firstResponder === p.field)
        #expect(p.field.string == "third ask")
        // The box has the keyboard now: its own arrows continue the browse.
        press(up: true, in: p)
        #expect(p.field.string == "second ask")
        press(up: false, in: p)
        press(up: false, in: p)
        #expect(p.field.string == "kept draft")
    }

    /// From outside, Up recalls even when the caret was on a later line of a multi-line draft.
    @Test func upFromOutsideRecallsWhateverTheCaretLine() {
        let p = pane()
        type("line one\nline two", in: p)
        p.window.makeFirstResponder(nil)
        #expect(p.controller.recallHistoryFromOutside(.older))
        #expect(p.field.string == "third ask")
    }

    /// Down from outside with no browse only focuses the box.
    @Test func downFromOutsideOnlyFocuses() {
        let p = pane()
        type("draft", in: p)
        p.window.makeFirstResponder(nil)
        #expect(p.controller.recallHistoryFromOutside(.newer))
        #expect(p.window.firstResponder === p.field)
        #expect(p.field.string == "draft")
    }

    /// Text inputs and a held transcript selection keep their arrows.
    @Test func textInputsKeepTheirArrows() {
        let p = pane()
        #expect(!p.controller.historyTakesArrowKeys(from: p.field))
        #expect(!p.controller.historyTakesArrowKeys(from: NSTextField()))
    }

    // MARK: The history model

    @Test func entriesAreTheSentMessagesNewestFirstWithoutRepeats() {
        var h = ComposerHistory()
        let entries = ["c", "b", "a"]
        #expect(h.step(.newer, current: "x", entries: entries) == nil)
        #expect(h.step(.older, current: "x", entries: entries) == "c")
        #expect(h.step(.older, current: "c", entries: []) == "b", "a browse reads its snapshot, not the entries now")
        h.textChanged(to: "b")
        #expect(h.isBrowsing)
        h.textChanged(to: "b!")
        #expect(!h.isBrowsing)
        #expect(ComposerHistory().shown == nil)
    }
}
