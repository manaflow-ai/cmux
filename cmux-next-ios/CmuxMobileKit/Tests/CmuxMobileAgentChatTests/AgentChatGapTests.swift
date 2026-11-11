import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A tail-first reattach's gap (`gapOpened`, then `gapPage`s) goes in where it belongs even when
/// the newest records changed what it touches: a retried turn renames the turn it goes before, a
/// subagent the gap started already has newer state, a prompt it queued still waits, an ask
/// it shows was answered later.
@MainActor
@Suite struct AgentChatGapTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_000_000)

    /// One finished turn's events.
    static func turn(_ id: String, _ reply: String = "reply") -> [AgentSessionEvent] {
        [.userMessage(text: "prompt \(id)", promptId: "p-\(id)", turnId: id, attachments: [], at: at),
         .turnStarted(turnId: id, at: at),
         .update(.agentMessageChunk(text: reply, messageId: "m-\(id)")),
         .turnResult(turnId: id, status: .completed, errorText: nil, at: at)]
    }

    /// A chat that had turn t0, then reattached tail-first with `tail` after a gap before `before`.
    static func store(tail: [AgentSessionEvent], before: String) -> AgentChatStore {
        let store = AgentChatStore(source: Source())
        store.nextFrame = nil
        store.apply(.batch(turn("t0")))
        store.apply(.batch([.gapOpened(beforeTurnID: before)] + tail))
        return store
    }

    /// The newest page's first turn failed and resumed as a new attempt (`turnRetried`): its id
    /// changed. The gap used to look for the old id, find nothing and close with its turns lost.
    @Test func theGapFollowsARetriedTurn() {
        let tail: [AgentSessionEvent] = [
            .userMessage(text: "prompt t5", promptId: "p-t5", turnId: "t5", attachments: [], at: Self.at),
            .turnStarted(turnId: "t5", at: Self.at),
            .turnResult(turnId: "t5", status: .failed, errorText: "overloaded", at: Self.at),
            .turnRetried(previousTurnID: "t5", turnID: "t5b"),
            .userMessage(text: "prompt t5", promptId: "p-t5", turnId: "t5b", attachments: [], at: Self.at),
            .turnResult(turnId: "t5b", status: .completed, errorText: nil, at: Self.at),
        ]
        let store = Self.store(tail: tail, before: "t5")
        #expect(store.gapBeforeTurnID == "t5b")
        store.apply(.gapPage(Self.turn("t1") + Self.turn("t2"), done: false))
        store.apply(.gapPage(Self.turn("t3"), done: true))

        #expect(store.turns.map(\.id) == ["t0", "t1", "t2", "t3", "t5b"])
        #expect(!store.isFillingGap)
    }

    /// A subagent the gap started, whose end came in the newest page: the newest page made it
    /// first (finished, with its last words). The gap's own transcript of it used to be thrown
    /// away; now it goes before the newer items, and the newer state stays.
    @Test func aSubagentTheNewestRecordsAlreadyShowKeepsItsNewerStateAndGetsItsHistory() {
        let tail: [AgentSessionEvent] = Self.turn("t5") + [
            .subagent(AgentSubagentChange(id: "sa", name: "Worker", state: .completed, at: Self.at)),
            .subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "late", messageId: "m-late")),
        ]
        let store = Self.store(tail: tail, before: "t5")
        let gap: [AgentSessionEvent] = [
            .userMessage(text: "prompt t1", promptId: "p-t1", turnId: "t1", attachments: [], at: Self.at),
            .turnStarted(turnId: "t1", at: Self.at),
            .subagent(AgentSubagentChange(id: "sa", name: "Worker", state: .running, at: Self.at)),
            .subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "early", messageId: "m-early")),
        ]
        store.apply(.gapPage(gap, done: false))
        // A live record changes it again while the gap fills.
        store.apply(.subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "live", messageId: "m-live")))
        store.apply(.gapPage([.subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "middle", messageId: "m-middle")),
                              .turnResult(turnId: "t1", status: .completed, errorText: nil, at: Self.at)], done: true))

        let agent = try? #require(store.subagent("sa"))
        #expect(agent?.state == .completed)
        #expect(agent?.turnID == "t1")
        let texts = agent?.items.compactMap { item -> String? in if case .message(_, let markdown) = item { markdown } else { nil } }
        #expect(texts == ["early", "middle", "late", "live"])
        #expect(store.subagents.filter { $0.id == "sa" }.count == 1)
        // Drawn under the gap's turn that started it, not under the newest turn.
        func groups(_ turn: String) -> [String] {
            store.turns.first { $0.id == turn }?.items.flatMap { item -> [String] in
                if case .subagents(_, let ids) = item { ids } else { [] }
            } ?? []
        }
        #expect(groups("t1") == ["sa"])
        #expect(groups("t5").isEmpty)
    }

    /// A subagent's message and tool call that go on across the gap's edge: "A" before it,
    /// "B" in it and "C" in the newest page are one message "ABC"; a tool call the gap changed
    /// and the newest page finished has both changes. The gap used to keep its own items and
    /// drop every newer change to them.
    @Test func aSubagentsMessageAndToolCallGoOnAcrossTheGapsEdge() {
        let store = AgentChatStore(source: Source())
        store.nextFrame = nil
        store.apply(.batch([
            .userMessage(text: "prompt t0", promptId: "p-t0", turnId: "t0", attachments: [], at: Self.at),
            .turnStarted(turnId: "t0", at: Self.at),
            .subagent(AgentSubagentChange(id: "sa", name: "Writer", state: .running, at: Self.at)),
            .subagent(AgentSubagentChange(id: "sb", name: "Reader", state: .running, at: Self.at)),
            .subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "A", messageId: "m1")),
            .subagentUpdate(subagentID: "sb", .toolCall(ACPToolCall(id: "tc1", title: "Read", kind: .read))),
        ]))
        let tail: [AgentSessionEvent] = Self.turn("t5") + [
            .subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "C", messageId: "m1")),
            .subagentUpdate(subagentID: "sb", .toolCallUpdate(ACPToolCallUpdate(toolCallId: "tc1", status: .completed))),
        ]
        store.apply(.batch([.gapOpened(beforeTurnID: "t5")] + tail))
        store.apply(.gapPage([.subagentUpdate(subagentID: "sa", .agentMessageChunk(text: "B", messageId: "m1"))], done: false))
        store.apply(.gapPage([.subagentUpdate(subagentID: "sb", .toolCallUpdate(ACPToolCallUpdate(toolCallId: "tc1", title: "Read a.swift"))),
                              .turnResult(turnId: "t0", status: .completed, errorText: nil, at: Self.at)], done: true))

        let texts = store.subagent("sa")?.items.compactMap { item -> String? in if case .message(_, let markdown) = item { markdown } else { nil } }
        #expect(texts == ["ABC"])
        let calls: [ACPToolCall] = store.subagent("sb")?.items.compactMap { item -> ACPToolCall? in if case .tool(let call) = item { call } else { nil } } ?? []
        #expect(calls.map(\.title) == ["Read a.swift"])
        #expect(calls.map(\.status) == [.completed])
    }

    /// A background subagent started in an earlier turn (t0) goes on in the gap after the chat's
    /// last turn (t1): its earlier messages and its turn stay, the gap's work and the newest
    /// page's are added on, and it is drawn once, under t0. The gap used to start only from the
    /// last turn's subagents, so it rebuilt this one from nothing and replaced the original.
    @Test func aSubagentFromAnEarlierTurnKeepsItsHistoryAndTurnAcrossTheGap() {
        let store = AgentChatStore(source: Source())
        store.nextFrame = nil
        store.apply(.batch([
            .userMessage(text: "prompt t0", promptId: "p-t0", turnId: "t0", attachments: [], at: Self.at),
            .turnStarted(turnId: "t0", at: Self.at),
            .subagent(AgentSubagentChange(id: "bg", name: "Watcher", state: .running, at: Self.at)),
            .subagentUpdate(subagentID: "bg", .agentMessageChunk(text: "first", messageId: "w1")),
            .turnResult(turnId: "t0", status: .completed, errorText: nil, at: Self.at),
        ] + Self.turn("t1")))
        let tail: [AgentSessionEvent] = Self.turn("t5") + [
            .subagentUpdate(subagentID: "bg", .agentMessageChunk(text: "third", messageId: "w3")),
        ]
        store.apply(.batch([.gapOpened(beforeTurnID: "t5")] + tail))
        store.apply(.gapPage(Self.turn("t2") + [
            .subagent(AgentSubagentChange(id: "bg", state: .running, at: Self.at)),
            .subagentUpdate(subagentID: "bg", .agentMessageChunk(text: "second", messageId: "w2")),
        ], done: true))

        #expect(store.turns.map(\.id) == ["t0", "t1", "t2", "t5"])
        let agent = try? #require(store.subagent("bg"))
        #expect(agent?.turnID == "t0")
        #expect(agent?.name == "Watcher")
        let texts = agent?.items.compactMap { item -> String? in if case .message(_, let markdown) = item { markdown } else { nil } }
        #expect(texts == ["first", "second", "third"])
        #expect(store.subagents.filter { $0.id == "bg" }.count == 1)
        let drawnIn = store.turns.filter { turn in
            turn.items.contains { item -> Bool in if case .subagents(_, let ids) = item { ids.contains("bg") } else { false } }
        }.map(\.id)
        #expect(drawnIn == ["t0"])
    }

    /// A prompt waiting before the link dropped, edited on the Mac in the gap: it shows the
    /// edit (taking it back must not bring the old text into the composer), and a prompt the gap
    /// queued goes after it, not ahead.
    @Test func aPromptQueuedBeforeTheGapTakesTheGapsEditAndStaysFirst() {
        let store = AgentChatStore(source: Source())
        store.nextFrame = nil
        store.apply(.batch(Self.turn("t0") + [.queued(text: "old", promptId: "q-1", position: 0)]))
        #expect(store.queue.map(\.text) == ["old"])
        store.apply(.batch([.gapOpened(beforeTurnID: "t5")] + Self.turn("t5")))
        store.apply(.gapPage([.queueUpdated(promptId: "q-1", text: "edited"),
                              .queued(text: "later", promptId: "q-2", position: 1)], done: true))

        #expect(store.queue.map(\.id) == ["q-1", "q-2"])
        #expect(store.queue.map(\.text) == ["edited", "later"])
    }

    /// A live edit of a prompt the gap put back in the queue stays: a later gap page's older
    /// edit of it does not undo it.
    @Test func aLiveQueueEditOutlastsALaterGapPage() {
        let store = Self.store(tail: Self.turn("t5"), before: "t5")
        store.apply(.gapPage([.queued(text: "first", promptId: "q1", position: 0)], done: false))
        #expect(store.queue.map(\.text) == ["first"])
        store.apply(.queueUpdated(promptId: "q1", text: "live"))
        store.apply(.gapPage([.queueUpdated(promptId: "q1", text: "older")] + Self.turn("t1"), done: true))
        #expect(store.queue.map(\.text) == ["live"])
    }

    /// An ask in the gap that a newer record answered shows answered in the gap's turn, not
    /// open; one the gap answered itself stays answered too.
    @Test func anAskTheNewestRecordsAnsweredShowsAnsweredInTheGap() {
        let allow = ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)
        func ask(_ id: String) -> AgentSessionEvent {
            .permissionRequest(ACPPermissionRequest(id: id, toolCall: ACPToolCall(id: "tool-\(id)", title: "Run", kind: .execute), options: [allow]))
        }
        let store = Self.store(tail: Self.turn("t5") + [.permissionDecision(permissionId: "late", optionId: "allow")], before: "t5")
        store.apply(.gapPage([.userMessage(text: "prompt t1", promptId: "p-t1", turnId: "t1", attachments: [], at: Self.at),
                              .turnStarted(turnId: "t1", at: Self.at),
                              ask("early"),
                              .permissionDecision(permissionId: "early", optionId: "allow")], done: false))
        // The ask the newer record answered comes on a later page.
        store.apply(.gapPage([ask("late"), .turnResult(turnId: "t1", status: .completed, errorText: nil, at: Self.at)], done: true))

        let records: [PermissionRecord] = store.turns.first { $0.id == "t1" }?.items.compactMap { item -> PermissionRecord? in if case .permission(let record) = item { record } else { nil } } ?? []
        #expect(records.map(\.request.id) == ["early", "late"])
        #expect(records.map(\.resolution) == [.chose(allow), .chose(allow)])
    }

    /// Prompts the gap queued: one still waiting shows in the queue (with a newer edit of it),
    /// one that ran in the gap or one the newest records took out does not.
    @Test func promptsTheGapQueuedStillWaitUnlessTheyLeft() {
        let tail: [AgentSessionEvent] = Self.turn("t5") + [
            .dequeued(promptId: "q3"),
            .queueUpdated(promptId: "q1", text: "edited later"),
            .queued(text: "newer", promptId: "q4", position: 0),
        ]
        let store = Self.store(tail: tail, before: "t5")
        let gap: [AgentSessionEvent] = [
            .queued(text: "waits", promptId: "q1", position: 0),
            .queued(text: "runs", promptId: "q2", position: 1),
            .queued(text: "removed later", promptId: "q3", position: 2),
            .queued(text: "edited in the gap", promptId: "q5", position: 3),
            .queueUpdated(promptId: "q1", text: "older edit"),
            .queueUpdated(promptId: "q5", text: "edited, in the gap"),
            .dequeued(promptId: "q2"),
        ] + Self.turn("t1")
        store.apply(.gapPage(gap, done: true))

        #expect(store.queue.map(\.id) == ["q1", "q5", "q4"])
        #expect(store.queue.map(\.text) == ["edited later", "edited, in the gap", "newer"])
    }
}
