import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-15, after trying NEXT on his iPhone: "Tho the animation for sending messages is
/// kinda ass". The composer cleared on tap, and the bubble popped in only when the Mac's record
/// of the prompt came back a round trip later. A prompt into an idle chat is drawn at once, and
/// the Mac's record takes that same turn over: its rows keep their ids (no pop), it is never
/// doubled, and one the Mac does not run goes back to the composer as before.
@MainActor
@Suite struct SentPromptShownTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    static func promptID(_ source: Recorder) throws -> String {
        guard case .prompt(_, _, _, let id, _)? = source.sent.last else { throw CancellationError() }
        return id
    }

    static func rowIDs(_ store: AgentChatStore) -> [String] {
        ChatTranscriptBuilder(diffs: store.diffs)
            .build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)
            .flatMap(\.rows).map(\.id)
    }

    @Test func aSentPromptShowsAtOnceAndTheMacsRecordKeepsItsRows() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "  run the tests\nand summarize  ")
        let id = try Self.promptID(source)
        let shown = try #require(store.turns.last)
        #expect(store.turns.count == 1)
        #expect(shown.isUnconfirmed)
        #expect(shown.prompt == "run the tests\nand summarize")
        // Drawn at once by the outgoing overlay (OutgoingMessagesView, #56098), not as a transcript row:
        // a message still on its way has no Working line and runs nothing until the Mac records it (#57933).
        #expect(!store.isRunning)
        #expect(store.waitingMessages.map(\.promptID) == [id])
        #expect(!Self.rowIDs(store).contains("u-\(AgentChatStore.localTurnID(id))"))
        #expect(store.justSentRowKey() == AgentChatStore.localTurnID(id))
        #expect(store.justSentRowKey(now: ProcessInfo.processInfo.systemUptime + 2) == nil, "only a moment after the send")

        store.apply(.userMessage(text: "run the tests\nand summarize", promptId: id, turnId: "t1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t1", at: Date()))
        #expect(store.turns.count == 1, "the record is the shown turn, not a second one")
        let turn = try #require(store.turns.last)
        #expect(turn.id == "t1")
        #expect(!turn.isUnconfirmed)
        #expect(turn.rowKey == AgentChatStore.localTurnID(id))
        #expect(store.waitingMessages.isEmpty)
        // The recorded turn's rows keep the bubble's key, so the overlay's bubble hands over in place.
        #expect(Self.rowIDs(store).contains("u-\(AgentChatStore.localTurnID(id))"))
        #expect(store.isRunning)

        // The turn goes on under the Mac's id: its answer and its end land in it.
        store.apply(.update(.agentMessageChunk(text: "All green.", messageId: "m1")))
        store.apply(.turnResult(turnId: "t1", status: .completed, errorText: nil, at: Date()))
        #expect(store.turns.last?.answerMarkdown == "All green.")
        #expect(store.turns.last?.status == .completed)
        #expect(!store.isRunning)
        #expect(Self.rowIDs(store).contains("a-\(AgentChatStore.localTurnID(id))"))
    }

    @Test func aReplayOfTheConfirmedTurnAddsNothing() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "go")
        let id = try Self.promptID(source)
        store.apply(.userMessage(text: "go", promptId: id, turnId: "t1", attachments: [], at: Date()))
        // A reattach replays the log: the turn is known by the Mac's id now.
        store.apply(.batch([.userMessage(text: "go", promptId: id, turnId: "t1", attachments: [], at: Date())]))
        #expect(store.turns.map(\.id) == ["t1"])
    }

    @Test func aPromptTheMacDidNotTakeGoesBackToTheComposer() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let id = try Self.promptID(source)
        #expect(store.turns.count == 1)
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: id, reason: "link down"))
        #expect(store.turns.isEmpty, "never shown as sent once it came back")
        #expect(store.returnedDraft?.text == "run the tests")
        #expect(store.canRetryPrompt)
        // Sent again it shows again, under the same prompt id, and the record confirms it once.
        store.send(prompt: "run the tests")
        #expect(try Self.promptID(source) == id)
        #expect(store.turns.count == 1)
        store.apply(.userMessage(text: "run the tests", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1"])
    }

    @Test func aPromptTheMacQueuedShowsInTheQueueOnly() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "later")
        let id = try Self.promptID(source)
        store.apply(.queued(text: "later", promptId: id, position: 1))
        #expect(store.turns.isEmpty)
        #expect(store.queue.map(\.text) == ["later"])
    }

    @Test func aTurnFromElsewhereFirstLeavesThePromptForItsOwnRecord() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "mine")
        let id = try Self.promptID(source)
        // The Mac ran another prompt first: its updates must not land in the shown bubble's turn.
        store.apply(.userMessage(text: "from the Mac", promptId: "other", turnId: "t1", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Working on it.", messageId: "m1")))
        // The waiting bubble stays last; the Mac's turn and its answer go before it.
        #expect(store.turns.map(\.id) == ["t1", AgentChatStore.localTurnID(id)])
        #expect(store.turns.first?.answerMarkdown == "Working on it.")
        #expect(store.turns.last?.answerMarkdown.isEmpty == true)
        store.apply(.turnResult(turnId: "t1", status: .completed, errorText: nil, at: Date()))
        store.apply(.userMessage(text: "mine", promptId: id, turnId: "t2", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1", "t2"], "each once, in the Mac's order")
        #expect(store.turns.last?.prompt == "mine")
    }

    @Test func aMessageIntoARunningTurnShowsAtOnceAsASteer() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "first", promptId: "p1", turnId: "t1", attachments: [], at: Date()))
        #expect(store.isRunning)
        store.send(prompt: "and the docs", steer: true)
        #expect(store.turns.count == 1, "no turn of its own: it goes into the running one")
        let steers = store.turns.last?.items.compactMap { item -> SteeredMessage? in
            if case .steer(let message) = item { message } else { nil }
        } ?? []
        #expect(steers.map(\.text) == ["and the docs"])
    }

    @Test func aSentPromptKeepsItsAttachmentsThroughTheRecord() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        let photo = AgentAttachment(kind: .image, name: "Photo", data: Data([0x89, 0x50]))
        store.send(prompt: "look", attachments: [photo])
        let id = try Self.promptID(source)
        #expect(store.turns.last?.attachments.map(\.name) == ["Photo"])
        store.apply(.userMessage(text: "look", promptId: id, turnId: "t1",
                                 attachments: [.recordedImage(id: "abc", name: nil)], at: Date()))
        #expect(store.turns.last?.attachments.map(\.name) == ["Photo"])
        #expect(store.turns.last?.attachments.first?.data != nil)
    }
}

/// The transcript's glide for a send runs on the composer's spring (`.cmuxMobileSmooth`).
@MainActor
@Suite struct ChatSendSpringTests {
    @Test func theSpringStartsAtRestAndSettlesInItsDuration() {
        #expect(ChatSendSpring.progress(0) == 0)
        #expect(ChatSendSpring.progress(0.05) < 0.3)
        #expect(ChatSendSpring.progress(ChatSendSpring.duration) > 0.98)
        #expect(ChatSendSpring.progress(ChatSendSpring.settleTime) > 0.9995)
        var last = 0.0
        for step in 1...60 {
            let p = ChatSendSpring.progress(Double(step) / 100)
            #expect(p >= last, "no overshoot or turn back (bounce 0)")
            last = p
        }
    }

    @Test func theRowsStartWhereTheyWereAndArriveAtTheBottom() {
        var settle = ChatSendSettle(rowIDs: ["u-k"], motion: .glide, fromHeight: 840)
        let began = settle.begin(contentHeight: 900, at: 10)
        #expect(began)
        // The first frame draws the rows where they were before the bubble went in.
        #expect(abs(160 - settle.remaining(at: 10) - 100) < 0.001)
        #expect(settle.remaining(at: 10.2) < 60)
        #expect(settle.isDone(at: 10 + ChatSendSpring.settleTime))
    }

    @Test func aRowGrowingMidGlideDoesNotJump() {
        var settle = ChatSendSettle(rowIDs: ["u-k"], motion: .glide, fromHeight: 450)
        let began = settle.begin(contentHeight: 500, at: 0)
        #expect(began)
        let before = settle.remaining(at: 0.1)
        // The working line measured 12 pt taller: the resting place moves down 12, and so must
        // what is left, so the drawn offset (resting − remaining) stays put this frame.
        settle.contentGrew(to: 512, at: 0.1)
        #expect(abs(settle.remaining(at: 0.1) - (before + 12)) < 0.001)
    }

    @Test func nothingToTravelIsNoGlide() {
        var settle = ChatSendSettle(rowIDs: ["u-k"], motion: .glide, fromHeight: 300)
        let began = settle.begin(contentHeight: 300, at: 0)
        #expect(!began)
    }
}
