@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Launch gives a tree without a workspace of the user's own its first
/// workspace (`FirstWorkspace`, `WindowManager.restore`).
@MainActor
struct FirstWorkspaceTests {
    private static func workspaces(_ snapshots: [WorkspaceSnapshot]) -> [WorkspaceModel] {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: snapshots))
        return services.daemon.store.workspaces
    }

    private static func home() -> WorkspaceSnapshot {
        var home = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "home"), name: "Home")
        home.kind = "home"
        return home
    }

    @Test func anEmptyTreeGetsAWorkspace() {
        #expect(FirstWorkspace.isNeeded(Self.workspaces([]), leftover: []))
    }

    /// Regression (dogfood 80e323c): the store's home workspace exists from
    /// the first connect, so a first launch counted it and opened on Home
    /// with "No workspaces" in the sidebar and no terminal.
    @Test func theHomeWorkspaceAloneStillGetsAWorkspace() {
        #expect(FirstWorkspace.isNeeded(Self.workspaces([Self.home()]), leftover: []))
    }

    @Test func aUserWorkspaceNeedsNoOther() {
        let user = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "user"), name: "code")
        #expect(!FirstWorkspace.isNeeded(Self.workspaces([Self.home(), user]), leftover: []))
    }

    @Test func leftoverIncognitoWorkspacesDoNotCount() {
        let user = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "user"), name: "private")
        let models = Self.workspaces([user])
        #expect(FirstWorkspace.isNeeded(models, leftover: models.map(\.id)))
    }

    /// Regression (cx-aha, hqffa2 first launch): on a fresh store the tree
    /// can report the home workspace before its `kind` row (ensure_home
    /// creates the workspace, then reloads the kind). That launch counted
    /// Home as the user's own, made no first workspace and opened on Home.
    /// The workspace `ensure_home` named is Home whatever its kind says yet.
    @Test func theHomeWorkspaceNamedByEnsureHomeCountsAsHomeBeforeItsKind() {
        let home = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "home"),
                                     resourceID: ResourceID(rawValue: "ws_home"), name: "Home")
        let models = Self.workspaces([home])
        #expect(models.first?.kind == nil, "the kind row has not arrived")
        #expect(FirstWorkspace.isNeeded(models, leftover: [], home: ResourceID(rawValue: "ws_home")))
        #expect(!FirstWorkspace.isNeeded(models, leftover: [], home: nil), "an unnamed workspace without a kind is the user's")
        let user = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "user"),
                                     resourceID: ResourceID(rawValue: "ws_user"), name: "code")
        #expect(!FirstWorkspace.isNeeded(Self.workspaces([home, user]), leftover: [], home: ResourceID(rawValue: "ws_home")))
    }
}
