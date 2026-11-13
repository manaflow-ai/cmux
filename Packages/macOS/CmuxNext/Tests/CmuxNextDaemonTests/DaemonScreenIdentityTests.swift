import Foundation
import Testing
@testable import CmuxNextDaemon

@MainActor struct DaemonScreenIdentityTests {
    private let first = "a1111111-1111-4111-8111-111111111111"
    private let second = "b2222222-2222-4222-8222-222222222222"

    @Test func enrichedIdentityDecodesScreenUUIDSeparatelyFromMachineAndSession() throws {
        let wire = Data("""
        {"id":1,"ok":true,"data":{"app":"cmux-tui","protocol":12,"generation":"boot",
        "machine_id":"machine_owner","registry_id":"session_registry","screen_device_id":"\(first.uppercased())"}}
        """.utf8)
        let identity = try WireCoding.decodeResponse(DaemonIdentity.self, from: wire)
        #expect(identity.screenDeviceID == first)
        #expect(identity.machineResourceID?.rawValue == "machine_owner")
        #expect(identity.sessionID == "session_registry")
        #expect(DaemonIdentity(generation: "older").screenDeviceID == nil)
        #expect(DaemonIdentity(screenDeviceID: "machine_owner", generation: "boot").screenDeviceID == nil)
    }

    @Test func readinessRotationAndRemovalApplyOnlyFromCurrentControlTransport() {
        let store = DaemonStore(), source = UUID()
        func envelope(_ event: DaemonEvent, index: UInt64, serial: UInt64 = 1, sourceID: UUID? = nil) -> DaemonEventEnvelope {
            .init(sequence: DaemonEventEnvelope.sequence(serial: serial, index: index), event: event, sourceID: sourceID ?? source)
        }
        _ = store.apply(batch: [envelope(.connected(DaemonIdentity(generation: "boot"), generationChanged: true), index: 0)])
        let ready = DaemonEvent.decode(name: "screen-device-changed", line: Data("{\"screen_device_id\":\"\(first.uppercased())\"}".utf8))
        #expect(ready == .screenDeviceChanged(first))
        #expect(ready.outlivesSnapshot)
        _ = store.apply(batch: [envelope(ready, index: 1)])
        #expect(store.identity?.screenDeviceID == first)
        _ = store.apply(batch: [envelope(.screenDeviceChanged(second), index: 2, sourceID: UUID())])
        #expect(store.identity?.screenDeviceID == first, "another connection cannot rotate this daemon's identity")
        _ = store.apply(batch: [envelope(.screenDeviceChanged(second), index: 3)])
        #expect(store.identity?.screenDeviceID == second)
        let removed = DaemonEvent.decode(name: "screen-device-changed", line: Data("{\"screen_device_id\":null}".utf8))
        _ = store.apply(batch: [envelope(removed, index: 4)])
        #expect(store.identity?.screenDeviceID == nil)
        _ = store.apply(.disconnected(reason: "gone"))
        _ = store.apply(batch: [envelope(ready, index: 5)])
        #expect(store.identity?.screenDeviceID == nil)
    }

    @Test func collapsedInboxAndSnapshotCannotDiscardScreenIdentity() {
        let store = DaemonStore(), source = UUID(), inbox = EventInbox(limit: 2)
        func envelope(_ event: DaemonEvent, _ index: UInt64) -> DaemonEventEnvelope {
            .init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: index), event: event, sourceID: source)
        }
        _ = store.apply(batch: [envelope(.connected(DaemonIdentity(generation: "boot"), generationChanged: true), 0)])
        let ready = envelope(.screenDeviceChanged(first), 1)
        _ = inbox.append(ready)
        _ = inbox.append(envelope(.treeChanged(transaction: nil), 2))
        _ = inbox.append(envelope(.treeChanged(transaction: nil), 3))
        let retained = inbox.take()
        #expect(retained.contains(ready))
        store.apply(snapshot: DaemonTree(workspaces: []))
        store.snapshotBarrier = DaemonEventEnvelope.sequence(serial: 4, index: 100)
        store.advanceAppliedSequence(to: store.snapshotBarrier)
        _ = store.apply(batch: retained)
        #expect(store.identity?.screenDeviceID == first)
        // A retained carrier from the old control serial cannot replace the current identity.
        _ = store.apply(batch: [.init(sequence: DaemonEventEnvelope.sequence(serial: 3, index: 101),
                                      event: .screenDeviceChanged(second), sourceID: source)])
        #expect(store.identity?.screenDeviceID == first)
    }

    @Test(arguments: ["{}", "{\"screen_device_id\":\"machine_owner\"}", "{\"screen_device_id\":17}"])
    func malformedChangeDoesNotClearAnIdentity(_ json: String) {
        let event = DaemonEvent.decode(name: "screen-device-changed", line: Data(json.utf8))
        guard case .unknown = event else { Issue.record("malformed screen identity became a change"); return }
    }
}
