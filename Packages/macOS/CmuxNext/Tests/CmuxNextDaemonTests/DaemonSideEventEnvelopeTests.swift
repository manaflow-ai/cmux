import Foundation
import Testing
@testable import CmuxNextDaemon

/// Inventory demand must retain its source even when a tree snapshot is newer.
///
/// No `.timeLimit`: every wait here is on a reply or an event from a python3
/// fixture, and none checks a deadline. In the full parallel package run, where
/// tests take 80-900 s of wall clock, the 1 minute limit expired on
/// realConnectionsStampNativeEventsAndSeparateEqualSerials before its two
/// fixtures answered. A fixture that never answers is a hang that
/// scripts/cmux-next/swift-test-with-hang-sampler.sh names and samples.
@MainActor
@Suite
struct DaemonSideEventEnvelopeTests {
    private let sourceID = UUID()

    @Test func onlyAppliedStampedConnectionChangesAdmitTheRegistryCarrier() throws {
        let store = DaemonStore()
        let connected = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 9, index: 0),
            event: .connected(DaemonIdentity(generation: "current"), generationChanged: true), sourceID: sourceID)
        _ = store.apply(batch: [connected])
        let admitted = try #require(store.sideEvents.controlStamp)
        #expect(admitted.sourceID == sourceID && admitted.serial == 9)
        store.apply(snapshot: DaemonTree(workspaces: []))
        _ = store.apply(batch: [.init(sequence: DaemonEventEnvelope.sequence(serial: 8, index: 1), event: demand, sourceID: UUID())])
        #expect(store.sideEvents.controlStamp == admitted)
        _ = store.apply(.disconnected(reason: "fixture"))
        #expect(store.sideEvents.controlStamp == nil)
        _ = store.apply(batch: [connected])
        _ = store.apply(.connected(DaemonIdentity(generation: "unstamped"), generationChanged: true))
        #expect(store.sideEvents.controlStamp == nil)
        _ = store.apply(batch: [connected])
        _ = store.apply(.daemonShutdown)
        #expect(store.sideEvents.controlStamp == nil)
    }

    private var demand: DaemonEvent {
        let line = #"{"event":"apps-agent-inventory-demand","sequence":2,"enabled":true}"#
        return DaemonEvent.decode(name: "apps-agent-inventory-demand", line: Data(line.utf8))
    }

    @Test func nativeSideEventsKeepTheirExactEnvelope() {
        let store = DaemonStore()
        var received: [DaemonEventEnvelope] = []
        let token = store.sideEvents.subscribeEnvelopes { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        let envelope = DaemonEventEnvelope(sequence: .max - 1, event: demand, sourceID: sourceID)
        _ = store.apply(batch: [envelope])
        #expect(received == [envelope])
        #expect(received.first?.connectionSerial == ((UInt64.max - 1) >> 40))
    }

    @Test func retainedOldDemandNeverInheritsTheNewSnapshotConnection() {
        let store = DaemonStore()
        let connected = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 9, index: 0),
            event: .connected(DaemonIdentity(generation: "new-control"), generationChanged: true), sourceID: sourceID)
        _ = store.apply(batch: [connected])
        store.apply(snapshot: DaemonTree(workspaces: []))
        store.snapshotBarrier = DaemonEventEnvelope.sequence(serial: 9, index: 100)
        store.advanceAppliedSequence(to: store.snapshotBarrier)
        var received: [DaemonEventEnvelope] = []
        let token = store.sideEvents.subscribeEnvelopes { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        let old = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 8, index: 20), event: demand, sourceID: sourceID)
        _ = store.apply(batch: [old])
        #expect(received == [old])
        #expect(received.first?.connectionSerial == 8)
    }

    @Test func collapsedInboxPreservesTheOriginalSourceStamp() {
        let inbox = EventInbox(limit: 2)
        let original = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 10), event: demand, sourceID: sourceID)
        _ = inbox.append(original)
        _ = inbox.append(DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 5, index: 1), event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 5, index: 2), event: .treeChanged(transaction: nil)))
        let store = DaemonStore()
        var received: [DaemonEventEnvelope] = []
        let token = store.sideEvents.subscribeEnvelopes { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        _ = store.apply(batch: inbox.take())
        #expect(received == [original])
    }

    @Test func terminalRegistryChangesSurviveSnapshotBarriersAndKeepTheirOwnerStamp() {
        let store = DaemonStore()
        let envelope = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 10),
            event: .terminalRegistryChanged(revision: 7), sourceID: sourceID)
        store.snapshotBarrier = DaemonEventEnvelope.sequence(serial: 4, index: 100)
        var received: [DaemonEventEnvelope] = []
        let token = store.sideEvents.subscribeEnvelopes { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        _ = store.apply(batch: [envelope])
        #expect(received == [envelope], "a tree snapshot cannot replace a terminal outcome invalidation")
    }

    @Test func aCollapsedInboxRetainsTerminalRegistryInvalidations() {
        let inbox = EventInbox(limit: 2)
        let original = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 10),
            event: .terminalRegistryChanged(revision: 7), sourceID: sourceID)
        _ = inbox.append(original)
        _ = inbox.append(.init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 11), event: .treeChanged(transaction: nil)))
        _ = inbox.append(.init(sequence: DaemonEventEnvelope.sequence(serial: 4, index: 12), event: .treeChanged(transaction: nil)))
        let store = DaemonStore()
        var received: [DaemonEventEnvelope] = []
        let token = store.sideEvents.subscribeEnvelopes { received.append($0) }
        defer { store.sideEvents.unsubscribe(token) }
        _ = store.apply(batch: inbox.take())
        #expect(received == [original])
    }

    @Test func unsequencedEventsStayLegacyAndUnsubscribingStopsStampedDelivery() {
        let store = DaemonStore()
        var legacy: [DaemonEvent] = []
        var stamped: [DaemonEventEnvelope] = []
        let oldToken = store.sideEvents.subscribe { legacy.append($0) }
        let token = store.sideEvents.subscribeEnvelopes { stamped.append($0) }
        defer { store.sideEvents.unsubscribe(oldToken) }
        _ = store.apply(demand)
        #expect(legacy == [demand])
        #expect(stamped.isEmpty)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: demand)])
        #expect(stamped.isEmpty, "a sequence alone cannot identify the source connection instance")
        let envelope = DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 1, index: 1), event: demand, sourceID: sourceID)
        _ = store.apply(batch: [envelope])
        #expect(stamped == [envelope])
        store.sideEvents.unsubscribe(token)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: envelope.sequence + 1, event: demand, sourceID: sourceID)])
        #expect(stamped == [envelope])
        #expect(legacy.count == 4)
    }

    @Test func realConnectionsStampNativeEventsAndSeparateEqualSerials() async throws {
        let script = #"""
        import json, sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            result = {}
            if frame.get('cmd') == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'same-owner-boot','capabilities':[]}
            if frame.get('cmd') == 'subscribe':
                print('{"event":"apps-agent-inventory-demand","sequence":2,"enabled":true}', flush=True)
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        var sources: Set<UUID> = []
        for _ in 0..<2 {
            let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
            let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-stamped-events-\(UUID().uuidString).sock", bridge: bridge),
                                              configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
            do {
                try await connection.start()
                var received: [DaemonEventEnvelope] = []
                for try await envelope in connection.events {
                    received.append(envelope)
                    if case .unknown("apps-agent-inventory-demand", _) = envelope.event { break }
                }
                #expect(received.count == 2)
                #expect(received.allSatisfy { $0.sourceID == connection.eventSourceID && $0.connectionSerial == 1 })
                sources.insert(connection.eventSourceID)
                await connection.close()
            } catch {
                await connection.close()
                throw error
            }
        }
        #expect(sources.count == 2, "replacing a connection cannot reuse source identity when its serial restarts")
    }
}
