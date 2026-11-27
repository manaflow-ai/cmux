import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Home getting focus puts the keyboard in the message box, and Cmd+V
/// anywhere in the pane that is not a text field pastes into the box
/// (Lawrence 2026-10-18). Drives a real `ChatController` over a loaded
/// conversation in an offscreen window.
@MainActor @Suite(.serialized) struct HomeKeyboardTests {
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

    private func pane() -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...6).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text("Message number \(i) with a few words")], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_keys"), title: "Chief", participants: people, lastSeq: 6,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_keys"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        return Pane(window: window, controller: controller)
    }

    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        fill(pb)
        return pb
    }

    private func pasteItem() -> NSMenuItem { NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v") }

    // MARK: Focus

    @Test func noResponderThePaneOrItsWindowGiveTheBoxTheKeyboard() {
        let p = pane()
        #expect(p.controller.composeShouldTakeKeyboard(from: nil))
        #expect(p.controller.composeShouldTakeKeyboard(from: p.window))
        #expect(p.controller.composeShouldTakeKeyboard(from: p.host))
        #expect(p.controller.composeShouldTakeKeyboard(from: p.host.paneHeader))
        // The bare transcript (no selection) is not a place to type.
        #expect(p.controller.composeShouldTakeKeyboard(from: p.host.scrollView.document))
    }

    @Test func textViewsAndFieldsKeepTheKeyboard() {
        let p = pane()
        #expect(!p.controller.composeShouldTakeKeyboard(from: p.field))
        #expect(!p.controller.composeShouldTakeKeyboard(from: NSTextField(string: "find")))
        #expect(!p.controller.composeShouldTakeKeyboard(from: NSTextView()))
    }

    @Test func aTextSelectionInTheTranscriptKeepsTheKeyboard() throws {
        let p = pane()
        let row = try #require(p.controller.demo?.lastTextRow(mine: false))
        #expect(p.controller.selection.selectWord(at: CGPoint(x: row.body.midX, y: row.body.midY)))
        #expect(!p.controller.selection.isEmpty)
        #expect(!p.controller.composeShouldTakeKeyboard(from: p.host.scrollView.document))
        p.controller.selection.clear()
        #expect(p.controller.composeShouldTakeKeyboard(from: p.host.scrollView.document))
    }

    @Test func aClickOnTheHeaderStripFocusesTheBox() {
        let p = pane()
        p.window.makeFirstResponder(p.host)
        p.controller.clicked(CGPoint(x: 300, y: 4))
        #expect(p.window.firstResponder === p.field)
    }

    // MARK: Cmd+V

    @Test func pasteFromThePaneFocusesTheBoxAndGoesThroughTheIntake() {
        let p = pane()
        let pb = board { $0.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png) }
        defer { pb.releaseGlobally() }
        p.field.pasteboard = pb
        var taken: [NSPasteboard] = []
        p.field.onPastePasteboard = { taken.append($0); return true }
        p.window.makeFirstResponder(p.host)
        p.host.paste(nil)
        #expect(p.window.firstResponder === p.field)
        #expect(taken.count == 1 && taken.first === pb)
        #expect(p.field.string.isEmpty)
    }

    /// The pasteboard's contents are stubbed: the CI Macs' pasteboard server
    /// answers reads of a fresh private board inconsistently.
    @Test func pasteIsEnabledForTextAndForWhatTheIntakeTakes() {
        let p = pane()
        var hasText = false, intakeTakes = false
        p.controller.pasteboardHasText = { _ in hasText }
        p.field.acceptsPastePasteboard = { _ in intakeTakes }
        let nothing = p.host.validateMenuItem(pasteItem())
        hasText = true
        let text = p.host.validateMenuItem(pasteItem())
        hasText = false; intakeTakes = true
        let files = p.host.validateMenuItem(pasteItem())
        #expect(nothing == false)
        #expect(text == true)
        #expect(files == true)
        // Other items keep AppKit's default (enabled).
        #expect(p.host.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")))
    }

    /// A text field in the pane keeps its own Cmd+V: its editor answers
    /// `paste(_:)` itself, so the responder chain never reaches the pane.
    @Test func aTextFieldKeepsItsOwnPaste() throws {
        let p = pane()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        p.host.addSubview(field)
        #expect(p.window.makeFirstResponder(field))
        let editor = try #require(p.window.firstResponder as? NSText)
        #expect(editor !== p.host && editor !== p.field)
        #expect(editor.responds(to: #selector(NSText.paste(_:))))
        #expect(!p.controller.composeShouldTakeKeyboard(from: editor))
    }
}
