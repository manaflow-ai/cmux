import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Perceived speed: on Cmd-N the window swapped the new workspace's content in on its
/// observation hop (`WindowController.show`), but the sidebar's rows and selection reached
/// `SidebarModel` on the bridge's own hop and the view drew them a hop after that. The first
/// frame of a new workspace showed its content beside the old sidebar: the old row selected and
/// no new row. The window now shows a workspace with its sidebar row listed and selected.
@MainActor struct SidebarSameTurnTests {
    private static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func listed(_ list: SidebarListView) -> [SidebarRowKey] { list.displayed.rows.map(\.key) }

    @Test func aShownNewWorkspaceListsAndSelectsItsRowInTheSameTurn() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try Self.connected()
        store.noteHandshake(identity) // capability checks read the handshake's identity
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["k1"]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"same-turn","workspace_key":"k1"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k1"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        controller.showWorkspace(requested: state.workspaceID)
        try await Task.sleep(for: .milliseconds(300))
        let list = controller.sidebar.container.sidebarView.list
        let old = SidebarRowKey.workspace(WorkspaceID("k1")), new = SidebarRowKey.workspace(WorkspaceID("k2"))
        try #require(list.selectedRowKey == old, "the fixture's first workspace is not the sidebar's selected row")

        // Cmd-N: the daemon lists the new workspace in the window, the window selects it, and its
        // workspace observation shows it (`WindowController.showWorkspace`).
        store.apply(snapshot: Self.tree(["k1", "k2"]))
        services.windows.registry.provisional[state.id] = ["k1", "k2"]
        state.showWorkspace("k2")
        controller.showWorkspace(requested: state.workspaceID)
        // What the frame that shows the new content commits: no observation turn has run.
        let firstListed = Self.listed(list)
        let firstSelected = list.selectedRowKey

        // The settled sidebar, after the observations ran: the fixture does list and select the row.
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.listed(list).contains(new))
        #expect(list.selectedRowKey == new)
        // The first frame already showed it.
        #expect(firstListed.contains(new))
        #expect(firstSelected == new)
    }
}
