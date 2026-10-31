import Foundation
import Observation
import Testing
@testable import CmuxMobileModel

/// verify/e2e-matrix.md #4: the workspace screen hung the main thread
/// (100% CPU, SwiftUI updating `TabsScreen` forever). The navigation
/// destination that makes `WorkspaceScreen` re-runs whenever something it
/// read changes, and building the screen's source wrote the store
/// (`takeFocusOnOpen` removed from an observed set even when it held
/// nothing). SwiftUI keeps the previous update's observation installed
/// while it re-runs a view, so a write during the update re-invalidates the
/// view it is updating: after one ordinary change (a tab title while typing,
/// a refresh after foreground) the update never ended.
@MainActor @Suite struct ViewUpdateLoopTests {
    /// Every observed property of the store, as a view could read it.
    static func readAll(_ store: AppStore) {
        _ = store.teams
        _ = store.activeTeamID
        _ = store.workspaces
        _ = store.feed
        _ = store.lastTabByWorkspace
        _ = store.teamDataState
        _ = store.isOffline
        _ = store.macLinkStatus
        _ = store.macData
        _ = store.macConnection
        _ = store.tracksMacData
        _ = store.accountMacCount
        _ = store.pendingWorkspaceIDs
        _ = store.workspaceAliases
        _ = store.seenAt
        _ = store.focusOnOpenWorkspaceIDs
    }

    /// Runs `evaluate` the way SwiftUI updates a view: once, then again
    /// while an observation installed before the run saw a change. Returns
    /// the number of runs (`limit` means it never settled).
    static func updateCount(_ store: AppStore, limit: Int = 20, _ evaluate: () -> Void) -> Int {
        var runs = 0
        let dirty = ObservedChanges()
        dirty.count = 1
        while dirty.count > 0, runs < limit {
            dirty.count = 0
            runs += 1
            withObservationTracking { readAll(store) } onChange: { dirty.count += 1 }
            evaluate()
        }
        return runs
    }

    /// What building a workspace's screen reads from the store.
    static func buildScreen(_ store: AppStore, _ id: String) {
        if let workspace = store.workspace(id: id) { _ = store.openingTab(for: workspace) }
        _ = store.wantsFocusOnOpen(id)
    }

    @Test func theHarnessCatchesAnUpdateThatWrites() {
        let store = AppStore.mock(tabMemory: .inMemory())
        #expect(Self.updateCount(store) { store.markSeen("ws-cmux") } == 20)
    }

    @Test func buildingAWorkspaceScreenSettlesInOneUpdate() throws {
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "gone"]))
        #expect(Self.updateCount(store) { Self.buildScreen(store, "ws-cmux") } == 1)
        // A workspace this phone just created (a focus request waiting).
        store.requestFocusOnOpen("ws-cmux")
        #expect(Self.updateCount(store) { Self.buildScreen(store, "ws-cmux") } == 1)
        #expect(store.wantsFocusOnOpen("ws-cmux"))
    }

    /// The write that looped: consuming a focus request that is not there.
    @Test func noFocusRequestMeansNoWrite() {
        let store = AppStore.mock(tabMemory: .inMemory())
        let notified = ObservedChanges()
        withObservationTracking { _ = store.focusOnOpenWorkspaceIDs } onChange: { notified.count += 1 }
        #expect(!store.takeFocusOnOpen("ws-cmux"))
        #expect(notified.count == 0)
        #expect(Self.updateCount(store) { _ = store.takeFocusOnOpen("ws-cmux") } == 1)
    }

    @Test func aFocusRequestIsConsumedOnce() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.requestFocusOnOpen("ws-cmux")
        #expect(store.wantsFocusOnOpen("ws-cmux"))
        #expect(store.takeFocusOnOpen("ws-cmux"))
        #expect(!store.wantsFocusOnOpen("ws-cmux"))
        #expect(!store.takeFocusOnOpen("ws-cmux"))
    }
}

/// Counts observation callbacks (they run synchronously on the main actor here).
final class ObservedChanges: @unchecked Sendable {
    var count = 0
}
