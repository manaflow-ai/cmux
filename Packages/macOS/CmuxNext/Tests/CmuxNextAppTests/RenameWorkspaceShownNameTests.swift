import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextPalette
import CmuxNextSidebar
import Foundation
import Testing

/// Rename Workspace opened on a name the sidebar did not show (Lawrence 2026-10-21): a workspace
/// on the daemon's default name reads as its front tab (a terminal's OSC title), and switching
/// tabs reads it as the new front tab, but the palette's rename prompt and workspace list read
/// the stored `workspace-N`. Every rename prompt starts from the name the row shows now.
@MainActor @Suite(.serialized) struct RenameWorkspaceShownNameTests {
    struct Fixture {
        let services: AppServices
        let controller: WindowController
        let workspace: String

        func close() {
            controller.teardown()
            controller.window?.close()
        }

        /// The name the window's sidebar row shows.
        var rowTitle: String? { controller.sidebar.model.workspace(SidebarWorkspaceID(workspace))?.title }
        /// The palette's workspace list (Cmd-P, the Rename Workspace override's prompt).
        var paletteTitle: String? {
            PaletteSourcesBridge.WorkspaceSource(services: services).workspaces.first { $0.id == workspace }?.title
        }
        /// What a Rename Workspace… argument prompt starts from (`isTargetName`).
        var promptTitle: String? {
            PaletteSourcesBridge.targetSource(services).title(of: ActionTargetRef(kind: .workspace, id: workspace))
        }

        func waitForRow(_ title: String) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, rowTitle != title { try await Task.sleep(for: .milliseconds(50)) }
            #expect(rowTitle == title)
        }
    }

    /// One window over workspace `k1`, on the daemon's default name `workspace-7` (`title` sets
    /// a user's name), one pane with two terminals the shell titled (OSC 0/2).
    static func fixture(title: String? = nil) async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let pane = PaneSnapshot(id: 1, name: "Main", tabs: [
            TabSnapshot(surface: 1, title: "vim notes.md", cwd: "/tmp/notes"),
            TabSnapshot(surface: 2, title: "htop", cwd: "/tmp/notes"),
        ])
        let workspace = WorkspaceSnapshot(id: 1, key: "k1", name: "workspace-7",
                                          screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])], title: title)
        var tree = DaemonTree(registryID: "s-local", workspaces: [workspace])
        tree.personal = PersonalState(sessions: [SessionRecord(id: "s-local")],
                                      workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: "k1", index: 0)])
        store.apply(snapshot: tree)
        let id = try #require(store.workspaces.first?.id)
        services.windows.registry.provisional["rename-window"] = ["k1"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "rename-window"))
        services.windows.select("k1", in: controller.state)
        controller.showWorkspace(requested: controller.state.workspaceID)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, controller.content == nil || controller.sidebar.model.workspace(SidebarWorkspaceID(id)) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        return Fixture(services: services, controller: controller, workspace: id)
    }

    @Test func renameStartsFromTheNameTheFrontTerminalGivesTheRow() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        try await fixture.waitForRow("vim notes.md")
        #expect(fixture.paletteTitle == "vim notes.md")
        #expect(fixture.promptTitle == "vim notes.md")
    }

    @Test func switchingTabsRenamesThePromptWithTheRow() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.close() }
        try await fixture.waitForRow("vim notes.md")
        let pane = try #require(fixture.services.machines.local.store.workspaces.first?.screens.first?.panes.first)
        let htop = try #require(fixture.services.machines.local.store.tab(surface: SurfaceID(rawValue: 2)))
        fixture.controller.state.selection.select(htop.id, in: pane.id)
        try await fixture.waitForRow("htop")
        #expect(fixture.paletteTitle == "htop")
        #expect(fixture.promptTitle == "htop")
    }

    @Test func aWorkspaceTheUserNamedKeepsItsName() async throws {
        let fixture = try await Self.fixture(title: "Release notes")
        defer { fixture.close() }
        try await fixture.waitForRow("Release notes")
        #expect(fixture.paletteTitle == "Release notes")
        #expect(fixture.promptTitle == "Release notes")
    }
}
