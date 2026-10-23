import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Cmd-N builds its New Tab page before the store lists the new workspace (b9cf636f08e: the
/// window mounts the workspace inside the intent, so the page must exist first). The window then
/// still shows the workspace the person is leaving, and the page's places were read as seen from
/// it: that workspace was left out of the bar's other workspaces ("current"), and the new one was
/// not listed yet, so a page opened from a workspace with 0 or 2+ places had no row for the
/// workspace just left. The page is built as seen from the new workspace.
@MainActor @Suite(.serialized)
struct CmdNFirstPageListsLeftWorkspaceTests {
    private static let host = "install:this-mac"

    /// The workspace the person leaves: two terminals (two places, so it lists as a workspace).
    private static func leftWorkspace() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [
            TabSnapshot(surface: 1, kind: .pty, title: "build", cwd: "/work/app"),
            TabSnapshot(surface: 2, kind: .pty, title: "server", cwd: "/work/app"),
        ])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "left"), name: "left", screens: [
            ScreenSnapshot(id: 1, active: true, activePane: 1, layout: .leaf(1), panes: [pane]),
        ])])
    }

    @Test func cmdNsFirstPageListsTheWorkspaceThePersonLeft() throws {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"], showcase: true)
        tabs.localHost = Self.host
        tabs.holdsTabs = { _ in true }
        try #require(tabs.canHostChat, "no agent page source")
        let daemon = DaemonService()
        daemon.store.apply(snapshot: Self.leftWorkspace())
        var asked: [String?] = []
        tabs.firstPageNewTab = { _, _, workspace in
            asked.append(workspace)
            return (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        }
        let key = WorkspaceKey(rawValue: "new")

        let shown = try #require(tabs.showWorkspace(key, name: "new", index: nil, cwd: nil, token: nil, on: daemon, repair: .init(daemon: daemon)))
        defer { shown.abandon() }

        // The page was built as seen from the new workspace, not from the one the window still showed.
        #expect(asked == [key.rawValue])
        // So the bar lists the workspace just left under its other workspaces.
        let sources = daemon.store.workspaces.map {
            NewTabPage.PlaceSource(id: $0.id, name: $0.displayName, tabs: $0.screens.flatMap(\.panes).flatMap(\.tabs))
        }
        let places = NewTabPage.places(sources, current: asked.first ?? nil, excluding: nil, home: "/home/person")
        #expect(places.workspaces.map(\.id) == ["left"])
    }
}
