import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Ctrl+J inserts a newline in Home's message box (Lawrence 2026-10-25), like Shift+Return.
/// (Pane rig copied from ComposerHistoryKeysTests.)
/// Up and Down in Home's message box recall the person's sent messages like a
/// shell's history (Lawrence 2026-10-19: "Up arrow. You need to do work
/// properly. We need to handle unfocus as well so that, like it is history").
/// Drives a real `ChatController` over a loaded conversation in an offscreen
/// window, with real arrow key-downs into the field.
@MainActor @Suite(.serialized) struct ComposerCtrlJNewlineTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    struct Pane {
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

    private func ctrlJ(in p: Pane) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber, context: nil,
                         characters: "\n", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
    }

    @Test func ctrlJInsertsANewlineAndDoesNotSend() {
        let p = pane()
        p.window.makeFirstResponder(p.field)
        p.field.insertText("ab", replacementRange: p.field.selectedRange())
        p.field.setSelectedRange(NSRange(location: 1, length: 0))
        p.field.keyDown(with: ctrlJ(in: p))
        #expect(p.field.string == "a\nb")
        #expect(p.controller.store?.state.ui.draft.text == "a\nb", "the draft keeps the text; nothing was sent")
    }
}
