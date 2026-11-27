import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The emoji button beside the message box (Leo 2026-10-20: "the emoji
/// button barely works"). The system picker opens at the key window's
/// current text input context, which AppKit moves to a new first responder
/// only after the event that focused it: the button must focus the box and
/// ask for the picker a turn later, with the box still holding the keyboard.
/// Drives a real `ChatController` in an offscreen window.
@MainActor @Suite(.serialized) struct EmojiButtonTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    struct Pane {
        let window: NSWindow
        let controller: ChatController
        var field: FieldTextView { controller.demo!.compose.textView.view }
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    private func pane() -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...2).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message number \(i)")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_emoji"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_emoji"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.bringWindowForward = { _ in }
        return Pane(window: window, controller: controller)
    }

    private func nextTurn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }

    @Test(arguments: ["transcript", "nothing"])
    func theButtonFocusesTheBoxThenOpensThePickerForIt(from place: String) async {
        let p = pane()
        switch place {
        case "transcript": p.window.makeFirstResponder(p.controller.host.scrollView.document)
        default: p.window.makeFirstResponder(nil)
        }
        // Each ask records whether the box held the keyboard then.
        var opened: [Bool] = []
        p.controller.openEmojiPalette = { [weak window = p.window, weak field = p.field] in
            opened.append(field != nil && window?.firstResponder === field)
        }

        p.controller.host.fieldChrome.onEmoji()

        let focused = p.window.firstResponder === p.field
        #expect(focused)
        // Not in the click's own turn: the box's input context is not current yet.
        #expect(opened.count == 0)
        await nextTurn()
        #expect(opened == [true])
    }

    /// The emoji goes in at the person's caret, not at the end of the draft.
    @Test func theCaretStaysWhereItWas() async {
        let p = pane()
        p.window.makeFirstResponder(p.field)
        p.field.insertText("Hello world", replacementRange: p.field.selectedRange())
        p.field.setSelectedRange(NSRange(location: 5, length: 0))
        p.window.makeFirstResponder(p.controller.host.scrollView.document)
        var opened = 0
        p.controller.openEmojiPalette = { opened += 1 }

        p.controller.host.fieldChrome.onEmoji()
        await nextTurn()

        let focused = p.window.firstResponder === p.field
        #expect(focused)
        #expect(p.field.selectedRange() == NSRange(location: 5, length: 0))
        #expect(opened == 1)
    }

    /// The picked emoji goes in at the person's caret in the middle of the draft, or over the
    /// words they selected, not at the end (Leo 2026-10-21). The system picker inserts a pick
    /// through the text input client it opened for, with no replacement range; that client must
    /// be the box, still holding the caret it had before the button took the click.
    @Test(arguments: ["caret", "selection"])
    func thePickedEmojiGoesInAtTheCaret(_ place: String) async {
        let p = pane()
        p.window.makeFirstResponder(p.field)
        p.field.insertText("Hello world", replacementRange: p.field.selectedRange())
        let before = place == "caret" ? NSRange(location: 5, length: 0) : NSRange(location: 6, length: 5)
        p.field.setSelectedRange(before)
        p.window.makeFirstResponder(p.controller.host.scrollView.document)
        var client: NSTextInputClient?
        p.controller.openEmojiPalette = { [weak window = p.window] in client = window?.firstResponder as? NSTextInputClient }

        p.controller.host.fieldChrome.onEmoji()
        await nextTurn()
        // The pick, as the system picker sends it.
        client?.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))

        let expected = place == "caret" ? "Hello😀 world" : "Hello 😀"
        #expect((client as AnyObject?) === p.field)
        #expect(p.field.string == expected)
        #expect(p.controller.store?.state.ui.draft.text == expected)
        #expect(p.field.selectedRange() == NSRange(location: before.location + ("😀" as NSString).length, length: 0))
    }

    /// The picker opens at the button, its arrow on it (Leo 2026-10-20: it opened at the left
    /// corner of the screen). The system picker places itself at the rect the focused field
    /// reports for its text; during the open that is the emoji button's rect, and the next
    /// selection change (the chosen emoji going in) gives the field its own rect back.
    @Test func thePickerOpensAtTheButton() async {
        let p = pane()
        p.window.makeFirstResponder(p.controller.host.scrollView.document)
        var reported: [NSRect] = []
        p.controller.openEmojiPalette = { [weak field = p.field] in
            guard let field else { return }
            reported.append(field.firstRect(forCharacterRange: field.selectedRange(), actualRange: nil))
        }

        p.controller.host.fieldChrome.onEmoji()
        await nextTurn()

        let glass = p.controller.host.fieldChrome.emojiGlass
        let button = p.window.convertToScreen(glass.convert(glass.bounds, to: nil))
        #expect(button.width > 0)
        #expect(reported == [button])
        p.field.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(p.field.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) != button)
    }

    /// While the Chief works the round button is Stop: it never opens the picker.
    @Test func whileWorkingTheButtonStops() async {
        let p = pane()
        var stops = 0, opened = 0
        p.controller.onStop = { stops += 1 }
        p.controller.openEmojiPalette = { opened += 1 }
        p.controller.isWorking = true

        p.controller.host.fieldChrome.onEmoji()
        await nextTurn()

        #expect(stops == 1)
        #expect(opened == 0)
    }

    /// Option-click on Stop is the host's Stop all agents; a plain click
    /// stops only the Chief's turn (coordinator 2026-10-20).
    @Test func optionClickOnStopStopsAllAgents() async {
        let p = pane()
        var stops = 0, all = 0
        p.controller.onStop = { stops += 1 }
        p.controller.onStopAll = { all += 1 }
        p.controller.isWorking = true

        p.controller.roundButtonClicked(option: true)
        #expect(all == 1)
        #expect(stops == 0)
        p.controller.roundButtonClicked(option: false)
        #expect(all == 1)
        #expect(stops == 1)
    }
}
