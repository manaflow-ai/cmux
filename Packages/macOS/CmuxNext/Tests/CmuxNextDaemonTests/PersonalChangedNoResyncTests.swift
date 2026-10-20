import Foundation
import Testing
@testable import CmuxNextDaemon

/// Every Cmd+N pins the new workspace to its room, and every personal
/// command emits `personal-changed`. Personal state is not the tree, so it
/// must not refetch and reconcile every workspace: at 1000 workspaces that
/// full resync was the cost of the create (CREATE-CLOSE-DESIGN.md C3).
@MainActor
struct PersonalChangedNoResyncTests {
    private static func store(workspaces count: Int) -> DaemonStore {
        let store = DaemonStore()
        let workspaces = (1...count).map { index in
            let raw = UInt64(index)
            let pane = PaneSnapshot(id: PaneID(rawValue: raw), tabs: [TabSnapshot(surface: SurfaceID(rawValue: raw))])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: raw), layout: .leaf(PaneID(rawValue: raw)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: raw), key: nil, name: "w\(index)", screens: [screen])
        }
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        return store
    }

    @Test(arguments: [10, 1000])
    func personalChangedDoesNotResyncTheTree(_ count: Int) {
        let store = Self.store(workspaces: count)
        let event = DaemonEvent.decode(name: "personal-changed", line: Data(#"{"event":"personal-changed"}"#.utf8))
        let followup = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event)])
        #expect(followup != .resync, "personal-changed refetched the whole tree of \(count) workspaces")
        #expect(followup != .none, "personal-changed must still refetch personal state")
    }
}
