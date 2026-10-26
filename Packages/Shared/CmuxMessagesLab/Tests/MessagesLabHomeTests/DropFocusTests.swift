import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// A file or picture dropped on Home (the pane or the field) puts the
/// keyboard in the message box with the caret at the end of the draft, and
/// the window becomes key (Lawrence 2026-10-19: "when i drop in an image or
/// attachment to imessage, i expect to be focused in text input area").
/// Drives a real `ChatController` over a loaded conversation in an
/// offscreen window; the window is never ordered front.
@MainActor @Suite(.serialized) struct DropFocusTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The host's intake: takes what `takes` says and records each board.
    final class Intake: ChatIntents {
        var takes = true
        var taken: [NSPasteboard] = []
        func threadMovedByUser() {}
        func messageLink(_ id: ID) -> String? { nil }
        func send() -> String? { nil }
        func react(_ ref: MessagesLabHome.PartRef, _ kind: MessagesLabHome.Reaction.Kind) {}
        var canReact: Bool { false }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool {
            guard takes else { return false }
            taken.append(pasteboard)
            return true
        }
        func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { takes }
        func statusLineClicked(_ rect: CGRect, in view: NSView) {}
        func draftChanged() {}
        func linkTapped(_ ref: MessagesLabHome.PartRef, url: String) {}
        func canCancelSend(_ message: ID) -> Bool { false }
        func cancelSend(_ message: ID) {}
        func canRetrySend(_ message: ID) -> Bool { false }
        func retrySend(_ message: ID) {}
        func deleteFailedSend(_ message: ID) {}
        func openAttachment(_ message: ID, _ attachment: ID) {}
        func toggleVideo(_ ref: MessagesLabHome.PartRef, _ attachment: ID) {}
        func videoState(_ ref: MessagesLabHome.PartRef) -> HomeVideoState { .poster }
        func scrolled() {}
        func rowsPlaced() {}
    }

    @MainActor struct Pane {
        let window: NSWindow
        let controller: ChatController
        let intake: Intake
        var field: FieldTextView { controller.demo!.compose.textView.view }
        var host: HostView { controller.host }
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// The pane; `forward` counts the times it asked for its window to become key.
    private func pane(forward: @escaping (NSWindow) -> Void = { _ in }) -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...4).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message number \(i)")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_drop"), title: "Chief", participants: people, lastSeq: 4,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_drop"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        let intake = Intake()
        controller.intents = intake
        controller.bringWindowForward = forward
        return Pane(window: window, controller: controller, intake: intake)
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/drop-focus.png") as NSURL])
        return pb
    }

    /// Types `text` into the field as the person would (the draft follows).
    private func type(_ text: String, in p: Pane) {
        p.window.makeFirstResponder(p.field)
        p.field.insertText(text, replacementRange: p.field.selectedRange())
    }

    @Test(arguments: ["transcript", "nothing"])
    func aDropOnThePaneFocusesTheBoxAtTheEndOfTheDraft(from place: String) {
        var forwarded: [NSWindow] = []
        let p = pane { forwarded.append($0) }
        type("Look at this", in: p)
        p.field.setSelectedRange(NSRange(location: 0, length: 0))
        switch place {
        case "transcript": p.window.makeFirstResponder(p.host.scrollView.document)
        default: p.window.makeFirstResponder(nil)
        }
        #expect(p.window.firstResponder !== p.field)
        let pb = board()
        defer { pb.releaseGlobally() }

        #expect(p.controller.takeDrop(pb))

        #expect(p.intake.taken.count == 1 && p.intake.taken.first === pb)
        #expect(p.window.firstResponder === p.field)
        #expect(p.field.string == "Look at this")
        #expect(p.field.selectedRange() == NSRange(location: ("Look at this" as NSString).length, length: 0))
        // The offscreen window is not key: the drop asks for it to come forward.
        #expect(forwarded.count == 1 && forwarded.first === p.window)
    }

    @Test func aDropOnTheFieldGoesToTheIntakeNotIntoTheText() {
        let p = pane()
        type("Draft", in: p)
        let pb = board()
        defer { pb.releaseGlobally() }

        #expect(p.field.onDropPasteboard(pb))

        #expect(p.intake.taken.count == 1)
        #expect(p.field.string == "Draft")
        #expect(p.window.firstResponder === p.field)
    }

    /// The person was typing in the box: a drop keeps their caret where it is.
    @Test func aFocusedBoxKeepsItsCaret() {
        let p = pane()
        type("Hello world", in: p)
        p.field.setSelectedRange(NSRange(location: 5, length: 0))
        let pb = board()
        defer { pb.releaseGlobally() }

        #expect(p.controller.takeDrop(pb))

        #expect(p.window.firstResponder === p.field)
        #expect(p.field.selectedRange() == NSRange(location: 5, length: 0))
        #expect(p.field.string == "Hello world")
    }

    /// A drop the intake refuses moves nothing: no focus, no window.
    @Test func aRefusedDropLeavesFocusAlone() {
        var forwarded = 0
        let p = pane { _ in forwarded += 1 }
        p.intake.takes = false
        p.window.makeFirstResponder(p.host.scrollView.document)
        let pb = board()
        defer { pb.releaseGlobally() }

        #expect(!p.controller.takeDrop(pb))

        #expect(p.window.firstResponder === p.host.scrollView.document)
        #expect(forwarded == 0)
    }

    /// The file picker's close (chosen or cancelled) uses the same step.
    @Test func afterThePickerTheBoxTakesTheKeyboard() {
        let p = pane()
        p.window.makeFirstResponder(nil)
        p.controller.focusComposeForTyping()
        #expect(p.window.firstResponder === p.field)
        #expect(p.field.selectedRange().location == (p.field.string as NSString).length)
    }
}
