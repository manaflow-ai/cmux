import CmuxNextDaemon
import Testing

/// An agent's browser session opens its tabs in the agent's own workspace,
/// never the focused one (user, 2026-11-18: REPL tabs opened in Home). The
/// store finds that pane from the caller's terminal or workspace key.
@MainActor
struct CallerPaneTests {
    nonisolated static let agentKey = "fbc6c273-1e11-4696-a320-1b29e00e73c7"

    /// Home (workspace 1) and the agent's workspace (2): its first screen's
    /// default pane is 3; its terminal `term_agent` is in pane 4.
    static func store() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let homePane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)])
        let home = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"),
                                     name: "Home", screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [homePane])])
        let first = PaneSnapshot(id: 3, tabs: [TabSnapshot(surface: 3)])
        let terminal = PaneSnapshot(id: 4, tabs: [TabSnapshot(surface: 4, terminalResourceID: "term_agent")])
        let screen = ScreenSnapshot(id: 2, active: true, activePane: 3,
                                    layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(3), b: .leaf(4)),
                                    panes: [first, terminal])
        let agent = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: agentKey), name: "agent work", screens: [screen])
        store.apply(snapshot: DaemonTree(workspaces: [home, agent]))
        return store
    }

    @Test func theCallersTerminalNamesItsPane() throws {
        let pane = try #require(Self.store().callerPane(workspace: nil, terminal: "term_agent"))
        #expect(pane.handle == 4)
    }

    @Test(arguments: [agentKey, agentKey.uppercased(), agentKey.replacingOccurrences(of: "-", with: "")])
    func theCallersWorkspaceKeyNamesItsDefaultPane(key: String) throws {
        let pane = try #require(Self.store().callerPane(workspace: key, terminal: nil))
        #expect(pane.handle == 3)
    }

    @Test func aTerminalThatIsGoneFallsBackToTheWorkspace() throws {
        let pane = try #require(Self.store().callerPane(workspace: Self.agentKey, terminal: "term_gone"))
        #expect(pane.handle == 3)
    }

    @Test func nothingKnownNamesNoPaneSoTheCallerNeverGetsHome() {
        #expect(Self.store().callerPane(workspace: "00000000-0000-0000-0000-00000000dead", terminal: "term_gone") == nil)
        #expect(Self.store().callerPane(workspace: nil, terminal: nil) == nil)
    }
}
