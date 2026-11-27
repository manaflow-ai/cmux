import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxMobileModel

/// A Mac's list arrives whole on every tree update. Setting the same
/// workspaces again must not notify the views that read them (the list
/// rebuilt its rows for nothing); a real change still does.
@MainActor
@Suite struct WorkspacePublishTests {
    private func observes(_ store: AppStore, _ change: () -> Void) -> Bool {
        let fired = Mutex(false)
        withObservationTracking { _ = store.workspaces } onChange: { fired.withLock { $0 = true } }
        change()
        return fired.withLock { $0 }
    }

    @Test func theSameWorkspacesDoNotNotify() {
        let store = AppStore.mock()
        let same = store.workspaces
        #expect(!observes(store) { store.workspaces = same })
        #expect(!observes(store) { store.replaceWorkspaces(macID: same[0].macID, with: same.filter { $0.macID == same[0].macID }) })
    }

    @Test func aChangedWorkspaceNotifies() {
        let store = AppStore.mock()
        var next = store.workspaces
        next[0].isWorking.toggle()
        #expect(observes(store) { store.workspaces = next })
        #expect(store.workspaces == next)
        #expect(observes(store) { store.renameWorkspace(next[1].id, to: "renamed") })
    }
}
