import Foundation
import Testing
@testable import CmuxNextDaemon

/// The instant-create guard (Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D; instant-new-surfaces): each
/// command's result is in the store's visible records in the same turn as its intent, with no
/// daemon connected at all, so nothing on the key path can wait for a reply. The daemon's answer
/// then takes the stand-in over in place, and a refusal removes it exactly.
@MainActor
struct InstantCreateIntentTests {
    private static let pane = PaneID(rawValue: 3)

    /// One workspace with one screen and one pane holding one terminal tab.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    private static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }

    // MARK: Cmd-N

    @Test func newWorkspaceShowsWithItsPageInTheIntentsTurn() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let tab = Self.page()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: tab), index: nil),
                     transaction: .generate())

        let shown = try #require(store.workspace(id: key.rawValue))
        #expect(shown.isProvisional)
        #expect(shown.name == "2")
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface])
        #expect(store.workspaces.count == 2)
    }

    @Test func daemonWorkspaceTakesTheModelOverAndKeepsThePageUntilItsTab() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let tab = Self.page()
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: tab), index: nil),
                     transaction: transaction)
        let shown = try #require(store.workspace(id: key.rawValue))

        // create-workspace answered: the daemon's workspace, no screen yet.
        let created = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9), key: key, name: "2")
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, created]))
        #expect(store.workspace(id: key.rawValue) === shown)
        #expect(!shown.isProvisional)
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface], "no frame shows it empty")

        // Its first tab landed: the daemon's records alone show it, under the same model.
        let pane = PaneID(rawValue: 10)
        var withTab = created
        withTab.screens = [ScreenSnapshot(id: ScreenID(rawValue: 11), active: true, activePane: pane, layout: .leaf(pane),
                                          panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 12), kind: .conversation)])])]
        store.noteSettledAtNextSnapshot(transaction)
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [Self.base, withTab]))
        #expect(store.pendingIntents.isEmpty)
        #expect(store.workspace(id: key.rawValue) === shown)
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [SurfaceID(rawValue: 12)])
    }

    @Test func refusedNewWorkspaceLeavesNothing() {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: Self.page()), index: nil),
                     transaction: transaction)
        store.rejectIntent(transaction)
        #expect(store.workspace(id: key.rawValue) == nil)
        #expect(store.workspaces.map(\.id) == [Self.baseKey.rawValue])
        #expect(store.mirrorViolations.isEmpty)
    }

    // MARK: Cmd-T

    @Test func newTabShowsInItsPaneInTheIntentsTurn() throws {
        let store = Self.store()
        let tab = Self.page()
        store.intend(.createTab(pane: Self.pane, provisional: tab), transaction: .generate())
        let pane = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first?.panes.first)
        #expect(pane.tabs.map(\.surface).last == tab.surface)
        #expect(pane.tabs.count == 2)
    }

    // MARK: Cmd-D, Cmd-Shift-D

    @Test(arguments: [SplitDirection.right, .down])
    func splitShowsItsPaneInTheIntentsTurn(direction: SplitDirection) throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: Self.pane, direction: direction, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
    }
}
