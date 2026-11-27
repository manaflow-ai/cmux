import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The message box's dictation (Leo 2026-10-20: the waveform in the field did nothing). The mic
/// stands in the empty field's trailing slot; while a session runs the words stream in at the caret
/// (each update replaces the last guess), Return or the finish button keeps them, Esc drops them
/// and leaves the draft as it was. Drives a real `ChatController` in an offscreen window with a
/// scripted engine.
@MainActor @Suite(.serialized) struct ComposeVoiceTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    final class Engine: HomeVoiceInput {
        var toggles = 0, finishes = 0, cancels = 0
        func toggleVoice() { toggles += 1 }
        func finishVoice() { finishes += 1 }
        func cancelVoice() { cancels += 1 }
    }

    struct Pane {
        let window: NSWindow
        let controller: ChatController
        let engine: Engine
        var field: FieldTextView { controller.demo!.compose.textView.view }
        var draft: String { controller.store?.state.ui.draft.text ?? "<none>" }
        func voice(_ phase: HomeVoicePhase, _ text: String = "", level: Float = 0, cancelled: Bool = false) {
            controller.voice.apply(HomeVoiceUpdate(phase: phase, text: text, level: level, cancelled: cancelled))
        }
        func type(_ text: String) {
            field.insertText(text, replacementRange: field.selectedRange())
        }
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
        let summary = ConversationSummary(id: ConversationID("conv_voice"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_voice"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.bringWindowForward = { _ in }
        let engine = Engine()
        controller.voice.input = engine
        window.makeFirstResponder(controller.demo!.compose.textView.view)
        return Pane(window: window, controller: controller, engine: engine)
    }

    /// At rest the mic replaces the drawn waveform in the empty field; text gives the slot to Send.
    @Test func theMicRestsInTheEmptyField() {
        let p = pane()
        let controls = p.controller.host.voiceControls
        #expect(!controls.isHidden)
        #expect(!controls.isListening)
        #expect(p.controller.demo!.compose.hidesWaveform)

        p.type("Hi")
        #expect(controls.isHidden)
        #expect(p.controller.host.sendButton.isShown)

        p.controller.host.voiceControls.onMic()
        #expect(p.engine.toggles == 1)
    }

    /// Idle -> listening -> the words stream in at the caret (each guess replaces the last) -> stop
    /// commits them, after a space, with the text around them kept.
    @Test func wordsStreamInAtTheCaretAndStopCommitsThem() {
        let p = pane()
        p.type("Ask the Chief")
        p.field.setSelectedRange(NSRange(location: 7, length: 0))  // after "Ask the"
        let reserveAtRest = p.controller.demo!.compose.trailingReserve

        p.voice(.starting)
        #expect(p.controller.voice.isActive)
        #expect(p.controller.host.voiceControls.isListening)
        #expect(!p.controller.host.sendButton.isShown)
        #expect(p.controller.demo!.compose.trailingReserve > reserveAtRest)

        p.voice(.listening, "very", level: 0.6)
        #expect(p.field.string == "Ask the very Chief")
        p.voice(.listening, "very kind", level: 0.4)
        #expect(p.field.string == "Ask the very kind Chief")
        #expect(p.draft == "Ask the very kind Chief")

        p.voice(.finalizing, "very kind")
        p.voice(.idle, "very kindly")
        #expect(p.field.string == "Ask the very kindly Chief")
        #expect(p.draft == "Ask the very kindly Chief")
        #expect(p.field.selectedRange() == NSRange(location: 19, length: 0))
        #expect(!p.controller.voice.isActive)
        #expect(p.controller.demo!.compose.trailingReserve == reserveAtRest)
        #expect(p.controller.host.sendButton.isShown)
    }

    /// Esc drops the session's words and leaves the draft as it was before the mic.
    @Test func escapeCancelsAndRestoresTheDraft() {
        let p = pane()
        p.type("Draft")
        p.voice(.starting)
        p.voice(.listening, "spoken words")
        #expect(p.field.string == "Draft spoken words")

        p.controller.escape()
        #expect(p.engine.cancels == 1)
        p.voice(.idle, "spoken words", cancelled: true)

        #expect(p.field.string == "Draft")
        #expect(p.draft == "Draft")
        #expect(!p.controller.voice.isActive)
    }

    /// Esc after Return (the words are kept, the engine is still flushing) leaves the words.
    @Test func escapeWhileFinishingKeepsTheWords() {
        let p = pane()
        p.type("Draft")
        p.voice(.starting)
        p.voice(.listening, "spoken words")
        p.voice(.finalizing, "spoken words")

        p.controller.escape()
        #expect(p.engine.cancels == 0)
        p.voice(.idle, "spoken words")

        #expect(p.field.string == "Draft spoken words")
        #expect(p.draft == "Draft spoken words")
    }

    /// "Listening…" shows in the empty field until the first words arrive.
    @Test func listeningLineShowsUntilWordsArrive() {
        let p = pane()
        p.voice(.starting)
        #expect(!p.controller.host.listeningLine.isHidden)
        #expect(p.controller.demo!.compose.hidesPlaceholder)
        p.voice(.listening, "hello")
        #expect(p.controller.host.listeningLine.isHidden)
        #expect(p.field.string == "hello")
        p.voice(.idle, "hello")
        #expect(p.field.string == "hello")
    }

    /// Return while dictating finishes the session (the words stay to edit); it does not send.
    @Test func returnFinishesInsteadOfSending() {
        let p = pane()
        p.voice(.starting)
        p.voice(.listening, "hello")
        p.field.onSend()
        #expect(p.engine.finishes == 1)
        #expect(p.field.string == "hello")
        p.controller.host.voiceControls.onFinish()
        #expect(p.engine.finishes == 2)
    }

    /// A key the person types while it listens keeps the words where they are and stops the
    /// session; later words do not land in their typing.
    @Test func typingWhileListeningStopsTheSession() {
        let p = pane()
        p.voice(.starting)
        p.voice(.listening, "hello")
        p.type("!")
        #expect(p.engine.finishes == 1)
        p.voice(.listening, "hello there")
        p.voice(.idle, "hello there")
        #expect(p.field.string == "hello!")
    }

    /// The splice alone: the space goes only after a word, and the range follows the shown words.
    @Test func spliceSpacing() {
        var after = ComposeVoiceSplice(text: "Hi" as NSString, caret: 2)
        #expect(after.piece("there") == " there")
        let first = after.replace(with: "there")
        #expect(first.range == NSRange(location: 2, length: 0))
        #expect(after.range == NSRange(location: 2, length: 6))
        let spaced = ComposeVoiceSplice(text: "Hi " as NSString, caret: 3)
        #expect(spaced.piece("there") == "there")
        let start = ComposeVoiceSplice(text: "" as NSString, caret: 0)
        #expect(start.piece("") == "")
        let before = ComposeVoiceSplice(text: "Chief" as NSString, caret: 0)
        #expect(before.piece("Ask the") == "Ask the ")
    }

    /// The committed words are their own undo step: one Undo takes them out and keeps the typing.
    @Test func theCommitIsOneUndoStep() throws {
        let p = pane()
        let undo = try #require(p.field.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping(); p.type("Ask the Chief"); undo.endUndoGrouping()

        p.voice(.starting)
        p.voice(.listening, "kindly")
        undo.beginUndoGrouping(); p.voice(.idle, "kindly"); undo.endUndoGrouping()
        #expect(p.field.string == "Ask the Chief kindly")

        undo.undo()
        #expect(p.field.string == "Ask the Chief")
        undo.undo()
        #expect(p.field.string.isEmpty)
    }

    /// Edit > Undo while words show takes them out first and stops the session, so the undo acts
    /// on the draft it was recorded against.
    @Test func undoWhileListeningUndoesTheDraft() throws {
        let p = pane()
        let undo = try #require(p.field.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping(); p.type("Draft"); undo.endUndoGrouping()

        p.voice(.starting)
        p.voice(.listening, "spoken words")
        #expect(p.field.string == "Draft spoken words")

        undo.undo()
        #expect(p.engine.cancels == 1)
        #expect(p.field.string.isEmpty)
        p.voice(.idle, "spoken words", cancelled: true)
        #expect(p.field.string.isEmpty)
        #expect(!p.controller.voice.isActive)
    }
}
