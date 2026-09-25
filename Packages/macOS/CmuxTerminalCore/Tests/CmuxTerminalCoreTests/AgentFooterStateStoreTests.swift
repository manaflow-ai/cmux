import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Agent footer state store")
@MainActor
struct AgentFooterStateStoreTests {
    @Test("Replays an update published before panel subscription")
    func updateIsReplayableBeforePanelSubscription() {
        let store = AgentFooterStateStore()
        let surfaceID = UUID()
        let lease = store.activate(surfaceID: surfaceID)
        let state = AgentFooterState(agent: "codex", contextPercent: 42)

        #expect(store.update(state, for: lease))
        #expect(store.snapshot(for: surfaceID) == state)
    }

    @Test("Rejects late updates and cleans retired state")
    func retirementRejectsLateUpdatesAndReleaseCleansState() {
        let store = AgentFooterStateStore()
        let surfaceID = UUID()
        let lease = store.activate(surfaceID: surfaceID)

        #expect(store.update(AgentFooterState(agent: "codex", contextPercent: 42), for: lease))
        #expect(store.retire(surfaceID: surfaceID))
        #expect(!store.update(AgentFooterState(agent: "stale", contextPercent: 1), for: lease))
        #expect(store.snapshot(for: surfaceID) == nil)

        store.release(lease)
        #expect(store.snapshot(for: surfaceID) == nil)
    }

    @Test("Rejects an old lease after surface reactivation")
    func oldLeaseCannotUpdateReactivatedSurface() {
        let store = AgentFooterStateStore()
        let surfaceID = UUID()
        let oldLease = store.activate(surfaceID: surfaceID)
        #expect(store.retire(surfaceID: surfaceID))
        store.release(oldLease)

        let newLease = store.activate(surfaceID: surfaceID)
        #expect(!store.update(AgentFooterState(agent: "old", contextPercent: 5), for: oldLease))
        #expect(store.update(AgentFooterState(agent: "new", contextPercent: 6), for: newLease))
        #expect(store.snapshot(for: surfaceID)?.agent == "new")
    }
}
