@testable import CmuxNextDaemon
import Testing

/// The store's event inbox applies each object's newest value once per frame
/// (plans/cmux-next/main-thread-budget.md): whole-value surface events coalesce; deltas and agent
/// statuses never do.
@Suite struct EventInboxCoalescingTests {
    private func title(_ surface: UInt64, _ text: String, _ sequence: UInt64) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: SurfaceID(rawValue: surface), title: text))
    }

    private func titles(_ batch: [DaemonEventEnvelope]) -> [String] {
        batch.compactMap { if case .titleChanged(_, let text) = $0.event { text } else { nil } }
    }

    @Test func aNewerTitleOfTheSameSurfaceReplacesTheOlderOne() {
        let inbox = EventInbox()
        #expect(inbox.append(title(1, "a", 1)))
        #expect(!inbox.append(title(2, "x", 2)), "one frame per non-empty buffer")
        _ = inbox.append(title(1, "b", 3))
        _ = inbox.append(title(1, "c", 4))
        let batch = inbox.take()
        #expect(titles(batch) == ["x", "c"], "surface 1's newest title applies once, after surface 2's")
        #expect(batch.map(\.sequence) == [2, 4])
        #expect(inbox.coalescedCount == 2)
    }

    @Test func coalescedEventsDoNotFillTheBuffer() {
        let inbox = EventInbox(limit: 2)
        for index in 0..<50 { _ = inbox.append(title(1, "t\(index)", UInt64(index + 1))) }
        let batch = inbox.take()
        #expect(titles(batch) == ["t49"])
        #expect(!batch.contains { if case .overflow = $0.event { true } else { false } }, "one live event never overflows")
    }

    @Test func treeDeltasAreNeverCoalesced() {
        let inbox = EventInbox()
        _ = inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: 2, event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: 3, event: .personalChanged))
        _ = inbox.append(DaemonEventEnvelope(sequence: 4, event: .personalChanged))
        #expect(inbox.take().map(\.sequence) == [1, 2, 3, 4])
    }

    /// Review 1 of pl-main-bc: `agent-changed` is not a whole value to the store. The roster
    /// records the transition from the old status to the new one, so every status reaches it.
    @Test func agentStatusesAreNeverCoalesced() {
        let inbox = EventInbox()
        let states: [AgentState] = [.working, .idle, .working, .blocked, .working]
        for (index, state) in states.enumerated() {
            let status = AgentStatus(surface: 1, state: state, source: "hook", updatedAtMs: UInt64(100 * (index + 1)))
            _ = inbox.append(DaemonEventEnvelope(sequence: UInt64(index + 1), event: .agentChanged(status)))
        }
        let batch = inbox.take()
        #expect(batch.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(inbox.coalescedCount == 0)
    }
}
