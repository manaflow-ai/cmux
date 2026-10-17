import Foundation
import Testing
@testable import CmuxNextDaemon

/// Native inventory subscriptions are independent of the workspace tree.
/// A tree resync and inbox overflow cannot acknowledge these lease events.
@MainActor
struct AgentInventoryWatchEventRetentionTests {
    private func event(_ name: String) -> DaemonEvent {
        let line = #"{"event":"\#(name)","machine":"machine_0123456789abcdef0123456789abcdef","watch_id":"inventory_watch_0123456789abcdef0123456789abcdef","revision":2,"reason":"agent_inventory.unavailable"}"#
        return DaemonEvent.decode(name: name, line: Data(line.utf8))
    }

    @Test(arguments: ["agent-inventory-changed", "agent-inventory-watch-ended"])
    func aTreeSnapshotCannotConsumeAnInventoryLeaseEvent(name: String) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: []))
        store.snapshotBarrier = 12
        store.advanceAppliedSequence(to: 12)
        var received: [DaemonEvent] = []
        let token = store.sideEvents.subscribe { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        let update = event(name)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 11, event: update)])
        #expect(received == [update], "the tree contains neither inventory revisions nor ended leases")
    }

    @Test(arguments: ["agent-inventory-changed", "agent-inventory-watch-ended"])
    func anOverflowedInboxRetainsTheInventoryLeaseEvent(name: String) {
        let inbox = EventInbox(limit: 2)
        let update = event(name)
        _ = inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: 2, event: update))
        _ = inbox.append(DaemonEventEnvelope(sequence: 3, event: .treeChanged(transaction: nil)))
        #expect(inbox.take().contains { $0.event == update }, "a resync cannot replace a native inventory event")
    }

    @Test func anUnrelatedUnknownEventStillBelongsToTheTreeBarrier() {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: []))
        store.snapshotBarrier = 12
        var received: [DaemonEvent] = []
        let token = store.sideEvents.subscribe { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 11, event: event("unknown-test-event"))])
        #expect(received.isEmpty)
    }
}
