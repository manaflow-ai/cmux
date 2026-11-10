import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A tail-first reattach's gap (`gapOpened`, then `gapPage`s) goes in where it belongs even when
/// the newest records changed what it touches: a retried turn renames the turn it goes before, a
/// subagent the gap started already has newer state, a prompt it queued still waits.
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
        let texts = agent?.items.compactMap { if case .message(_, let markdown) = $0 { markdown } else { nil } }
        #expect(texts == ["early", "middle", "late", "live"])
        #expect(store.subagents.filter { $0.id == "sa" }.count == 1)
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
