import Foundation
import Testing
@testable import CmuxNextDaemon

/// The off-main buffer between the daemon's event stream and the main actor.
@MainActor @Suite struct EventInboxTests {
    /// Regression: while the main actor is busy (or a resync holds the
    /// inbox for up to the 10 s snapshot deadline) a delta storm grew the
    /// inbox without bound (architecture.md 5a: no unbounded buffers).
    /// Past the cap the inbox now collapses into one overflow marker, which
    /// the store answers with a single snapshot, keeping lifecycle events
    /// and transaction echoes.
    @Test func stormCollapsesIntoOneResyncAndKeepsEchoesAndLifecycle() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let store = DaemonStore()
        store.apply(snapshot: tree)
        store.intend(.renameTab(surface: 3, name: "mine"), transaction: "tx-early")
        let inbox = EventInbox()
        var sequence: UInt64 = 0
        func push(_ event: DaemonEvent) {
            sequence += 1
            _ = inbox.append(DaemonEventEnvelope(sequence: sequence, event: event))
        }
        push(.treeChanged(transaction: "tx-early"))
        for index in 0..<10_000 { push(.titleChanged(surface: 3, title: "t\(index)")) }
        push(.disconnected(reason: "eof"))
        for index in 0..<10_000 { push(.titleChanged(surface: 3, title: "u\(index)")) }

        let batch = inbox.take()
        #expect(batch.count < 64)
        #expect(batch.contains { if case .disconnected = $0.event { true } else { false } })
        #expect(batch.contains { if case .overflow = $0.event { true } else { false } })
        #expect(store.apply(batch: batch) == .resync)
        // The echo arrived as a `tree-changed`: the rename stays shown until
        // the snapshot covering it is applied, then leaves the log.
        #expect(store.hasPendingIntents)
        #expect(store.tab(surface: 3)?.name == "mine")
        store.apply(snapshot: tree)
        store.advanceAppliedSequence(to: sequence)
        #expect(!store.hasPendingIntents)
        #expect(inbox.take().isEmpty)
    }

    /// Regression (apps-v1): the app supervisor's events (`apps-scene`,
    /// `apps-changed`, `apps-provider-request`) are in no tree snapshot. A
    /// storm that collapses into a resync must keep them, and the store must
    /// deliver them to its side events even when the snapshot covers their
    /// sequence, or a mount loses scene batches and a provider call is never
    /// answered.
    @Test func aResyncDeliversTheAppsEventsInTheInbox() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let store = DaemonStore()
        store.apply(snapshot: tree)
        let inbox = EventInbox()
        var sequence: UInt64 = 0
        func push(_ event: DaemonEvent) {
            sequence += 1
            _ = inbox.append(DaemonEventEnvelope(sequence: sequence, event: event))
        }
        let scene = DaemonEvent.unknown(name: "apps-scene", payload: .object(["event": .string("apps-scene"), "mount_id": .string("m1")]))
        let request = DaemonEvent.unknown(name: "apps-provider-request", payload: .object(["event": .string("apps-provider-request"),
                                                                                          "request_id": .number(4)]))
        for index in 0..<10_000 { push(.titleChanged(surface: 3, title: "t\(index)")) }
        push(scene)
        for index in 0..<10_000 { push(.titleChanged(surface: 3, title: "u\(index)")) }
        push(request)
        let batch = inbox.take()
        #expect(batch.contains { $0.event == scene } && batch.contains { $0.event == request })
        var delivered: [String] = []
        store.sideEvents.subscribe { if case .unknown(let name, _) = $0 { delivered.append(name) } }
        // The snapshot that answers the overflow covers every sequence in the batch.
        store.snapshotBarrier = sequence
        store.apply(batch: batch)
        #expect(delivered == ["apps-scene", "apps-provider-request"])
    }

    @Test func belowTheCapEveryEventIsKeptInOrder() {
        let inbox = EventInbox()
        #expect(inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 3, title: "a"))))
        #expect(!inbox.append(DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 3, title: "b"))))
        #expect(inbox.take().map(\.sequence) == [1, 2])
    }
}

@MainActor @Suite struct StoreIdentityTests {
    private static func identity(generation: String, capabilities: [String]) throws -> DaemonIdentity {
        let list = "[" + capabilities.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":\#(list),"session":"t","pid":1,"registry_id":"r","generation":"\#(generation)","workspace_revision":0}"#
        return try WireCoding.decoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Regression: the app kept the identity of the first daemon it reached,
    /// so after the daemon restarted (crash, version handoff) capability
    /// checks answered for the old one and hid or offered the wrong features.
    @Test func reconnectToANewDaemonReplacesTheIdentity() throws {
        let store = DaemonStore()
        let first = try Self.identity(generation: "A", capabilities: [])
        let second = try Self.identity(generation: "B", capabilities: [DaemonCapabilities.shared.batchClose])
        store.apply(.connected(first, generationChanged: false))
        #expect(store.identity?.supports(DaemonCapabilities.shared.batchClose) == false)
        store.apply(.disconnected(reason: "eof"))
        #expect(store.identity == first)
        store.apply(.connected(second, generationChanged: true))
        #expect(store.identity?.supports(DaemonCapabilities.shared.batchClose) == true)
    }
}
