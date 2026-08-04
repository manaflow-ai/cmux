import Testing
@testable import CmuxAgentReplica

@MainActor @Suite struct SessionDirectoryReplicaTests {
    @Test func versionGatingDropsRegressionAndEqualButAppliesHigher() {
        let store = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "e1"))

        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(phase: .idle, version: 2)), origin: .resync)
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(phase: .working, version: 1)), origin: .live)
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(phase: .needsInput, version: 2)), origin: .live)
        #expect(store.sessions.first?.phase == .idle)
        #expect(store.lastAppliedOrigin == .resync)

        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(phase: .working, version: 3)), origin: .resync)
        #expect(store.sessions.first?.phase == .working)
        #expect(store.lastAppliedOrigin == .resync)
    }

    @Test func removalIsVersionGated() {
        let store = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "e1"))
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(version: 5)), origin: .live)
        store.apply(.sessionRemoved(id: ReplicaTestSupport.session, version: ReplicaTestSupport.version(4)), origin: .live)
        #expect(store.sessions.count == 1)
        store.apply(.sessionRemoved(id: ReplicaTestSupport.session, version: ReplicaTestSupport.version(6)), origin: .live)
        #expect(store.sessions.isEmpty)
    }

    @Test func replaceAllResetsVersionGateAndSortsByUrgencyThenRecency() {
        let store = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "old"))
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(version: 99)), origin: .live)

        store.replaceAll([
            ReplicaTestSupport.snapshot(id: ReplicaTestSupport.otherSession, phase: .working, version: 1, recency: 3),
            ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .needsInput, version: 1, recency: 1),
            ReplicaTestSupport.snapshot(id: AgentSessionID(rawValue: "ended"), phase: .ended, version: 1, recency: 100),
        ], epoch: ReplicaEpoch(rawValue: "new"))

        #expect(store.sessions.map(\.id) == [ReplicaTestSupport.session, ReplicaTestSupport.otherSession, AgentSessionID(rawValue: "ended")])
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .idle, version: 2)), origin: .live)
        #expect(store.sessions.first?.phase == .working)
    }

    @Test func replaceAllKeepsHigherVersionWhenPullContainsDuplicateIDs() {
        let store = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "old"))
        store.replaceAll([
            ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .idle, version: 1),
            ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .working, version: 3),
            ReplicaTestSupport.snapshot(id: ReplicaTestSupport.session, phase: .needsInput, version: 2),
        ], epoch: ReplicaEpoch(rawValue: "new"))

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.phase == .working)
    }

    @Test func epochChangeDropsDirectoryState() {
        let store = SessionDirectoryReplica(epoch: ReplicaEpoch(rawValue: "e1"))
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(version: 1)), origin: .live)
        store.handleEpochChange(to: ReplicaEpoch(rawValue: "e2"))

        #expect(store.sessions.isEmpty)
        #expect(store.epoch == ReplicaEpoch(rawValue: "e2"))
        store.apply(.sessionUpserted(ReplicaTestSupport.snapshot(version: 1)), origin: .live)
        #expect(store.sessions.count == 1)
    }
}
