import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app half of one create or close at 10, 100, 500 and 1000
/// workspaces (CREATE-CLOSE-DESIGN.md): the delta the daemon sends for it,
/// against the full resync (`apply(snapshot:)`) a `tree-changed` or
/// `personal-changed` costs. Prints `STORE-CREATE-CLOSE` lines for the
/// fleet log; asserts only that the deltas apply without a resync.
@MainActor
struct CreateCloseStoreBench {
    private static func workspace(_ raw: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: raw), tabs: [TabSnapshot(surface: SurfaceID(rawValue: raw))])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: raw), layout: .leaf(PaneID(rawValue: raw)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: raw), key: nil, name: "w\(raw)", screens: [screen])
    }

    private static func tree(_ count: Int) -> DaemonTree {
        DaemonTree(workspaces: (1...count).map { workspace(UInt64($0)) })
    }

    private static func median(_ samples: [Duration]) -> Duration {
        samples.sorted()[samples.count / 2]
    }

    private static func micros(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000
    }

    @Test(arguments: [10, 100, 500, 1000])
    func createCloseCostAtScale(_ count: Int) {
        let clock = ContinuousClock()
        let store = DaemonStore()
        store.apply(snapshot: Self.tree(count))
        let middle = UInt64(count / 2)
        var resyncs: [Duration] = [], tabs: [Duration] = [], workspaces: [Duration] = []
        var revision: UInt64 = 0
        for rep in 0..<7 {
            // What one tree-changed costs the app after the daemon's read:
            // the whole tree reconciled (one more workspace each time).
            let grown = DaemonTree(workspaces: (1...count).map { Self.workspace(UInt64($0)) } + [Self.workspace(UInt64(100_000 + rep))])
            resyncs.append(clock.measure { store.apply(snapshot: grown) })
            store.apply(snapshot: Self.tree(count))

            // A terminal tab created and closed in the middle workspace, as deltas.
            let surface = SurfaceID(rawValue: UInt64(200_000 + rep))
            let delta = TabDelta(workspace: WorkspaceHandle(rawValue: middle), screen: ScreenID(rawValue: middle), pane: PaneID(rawValue: middle),
                                 surface: surface, index: 1, entity: TabSnapshot(surface: surface))
            var followups: [DaemonStore.Followup] = []
            tabs.append(clock.measure {
                followups.append(store.apply(.tabAdded(delta)))
                followups.append(store.apply(.tabClosed(delta)))
            })
            #expect(followups.allSatisfy { $0 == .none }, "tab deltas resynced at \(count) workspaces")

            // A workspace created and closed, as deltas.
            let created = UInt64(300_000 + rep)
            revision = store.workspaceRevision
            let added = WorkspaceDelta(workspace: WorkspaceHandle(rawValue: created), index: count / 2, entity: Self.workspace(created),
                                       workspaceRevision: revision + 1)
            let closed = WorkspaceDelta(workspace: WorkspaceHandle(rawValue: created), index: nil, entity: Self.workspace(created),
                                        workspaceRevision: revision + 2)
            followups.removeAll()
            workspaces.append(clock.measure {
                followups.append(store.apply(.workspaceAdded(added)))
                followups.append(store.apply(.workspaceClosed(closed)))
            })
            #expect(followups.allSatisfy { $0 == .none }, "workspace deltas resynced at \(count) workspaces")
        }
        print("STORE-CREATE-CLOSE n=\(count) resync_us=\(Self.micros(Self.median(resyncs))) tab_delta_pair_us=\(Self.micros(Self.median(tabs))) workspace_delta_pair_us=\(Self.micros(Self.median(workspaces)))")
    }
}
