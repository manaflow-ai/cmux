import Testing
@testable import CmuxNextDaemon

/// "There is a lot of lag in terminal when stuff in the sidebar rearranges" (sidebar churn B):
/// `onWorkspaceListChanged` runs the App's whole window-membership pass
/// (`WindowManager.reconcileMembership`, O(every workspace)). It must run only when a workspace
/// joins or leaves the store, never for a move, a group change or a change to one workspace,
/// which leave every window's membership as it was.
@MainActor
struct WorkspaceListHookTests {
    private static let group = WorkspaceGroupID(rawValue: "group-a")

    private static func workspace(_ number: Int, group: WorkspaceGroupID? = nil, title: String? = nil) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(number)), key: WorkspaceKey(rawValue: "ws-\(number)"),
                          name: "Workspace \(number)", group: group, title: title)
    }

    /// A loaded store of three workspaces and one group, with a hook that counts its runs.
    private static func loaded() -> (DaemonStore, () -> Int) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: (1...3).map { workspace($0) },
                                         groups: [WorkspaceGroupSnapshot(id: group, name: "A")]))
        var runs = 0
        store.onWorkspaceListChanged = { runs += 1 }
        return (store, { runs })
    }

    @Test func aMoveAGroupChangeAndAWorkspaceChangeNeverRunTheMembershipHook() {
        let (store, runs) = Self.loaded()
        // Move to the top (`workspace <id> move --index 0`).
        #expect(store.apply(.workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 3), index: 0,
                                                           entity: Self.workspace(3), workspaceRevision: 11))) == .none)
        #expect(store.workspaces.map(\.id) == ["ws-3", "ws-1", "ws-2"])
        // Into a group at its top (`workspace group <g> add --workspace <id> --index 0`).
        #expect(store.apply(.workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: 0,
                                                           entity: Self.workspace(2, group: Self.group), workspaceRevision: 12))) == .none)
        #expect(store.workspaces.first?.group == Self.group)
        // A change to one workspace (its title, color, status).
        #expect(store.apply(.workspaceChanged(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 1), index: 2,
                                                             entity: Self.workspace(1, title: "Renamed"), workspaceRevision: 13))) == .none)
        // The same moves in one batch.
        store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 1), index: 0,
                                                                                    entity: Self.workspace(1), workspaceRevision: 14))),
            DaemonEventEnvelope(sequence: 2, event: .workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 3), index: 0,
                                                                                    entity: Self.workspace(3, group: Self.group), workspaceRevision: 15))),
        ])
        #expect(store.workspaces.first?.id == "ws-3")
        #expect(runs() == 0, "the membership hook ran \(runs()) times for moves and one-workspace changes")
    }

    @Test func aWorkspaceThatJoinsOrLeavesRunsTheMembershipHookOnce() {
        let (store, runs) = Self.loaded()
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 4), index: 0,
                                                   entity: Self.workspace(4), workspaceRevision: 11)))
        #expect(runs() == 1)
        store.apply(.workspaceClosed(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 1), index: nil,
                                                    entity: Self.workspace(1), workspaceRevision: 12)))
        #expect(runs() == 2)
        // A snapshot that only reorders keeps the membership.
        store.apply(snapshot: DaemonTree(workspaceRevision: 13, workspaces: [4, 3, 2].map { Self.workspace($0) },
                                         groups: [WorkspaceGroupSnapshot(id: Self.group, name: "A")]))
        #expect(runs() == 2)
        // One that drops a workspace does not.
        store.apply(snapshot: DaemonTree(workspaceRevision: 14, workspaces: [4, 3].map { Self.workspace($0) },
                                         groups: [WorkspaceGroupSnapshot(id: Self.group, name: "A")]))
        #expect(runs() == 3)
    }
}
