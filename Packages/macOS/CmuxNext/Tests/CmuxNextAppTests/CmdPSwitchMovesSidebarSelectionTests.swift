import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/22997: switching workspace with Cmd-P and Enter showed the
/// new workspace, but the sidebar kept drawing the old row selected. A Cmd-P switch draws the chosen
/// workspace's row selected, as a click on that row does. Runs the palette's Enter on its row against a
/// same-tree cmux-tui daemon and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct CmdPSwitchMovesSidebarSelectionTests {
    @Test func cmdPEnterDrawsTheChosenWorkspaceSelected() async throws {
        try await PinnedPageTests.withApp { services, _ in
            // Cmd-P is the palette's action: the app binds it at launch (AppDelegate), the harness does not.
            services.palette.bindRegistryActions()
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let window = try #require(services.windows.active)
            try #require(window.window).setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let view = window.sidebar.container.sidebarView
            let model = window.sidebar.model
            @MainActor func describe() -> String {
                "window shows \(window.state.workspaceID ?? "nil"), sidebar model \(String(describing: model.selectedItem)), "
                    + "draws \(SidebarCmdNumberTwiceTests.drawnSelection(view)), palette open \(services.palette.isVisible)"
            }
            let from = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "cmdp-from"), into: window.state.id)
            let to = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "cmdp-to"), into: window.state.id)
            try await PinnedPageTests.until({ model.lists(WorkspaceID(from)) && model.lists(WorkspaceID(to)) }, report: describe)
            services.windows.show(workspaceID: from, in: window.state)
            try await PinnedPageTests.until({ SidebarCmdNumberTwiceTests.drawnSelection(view) == "row:\(SidebarRowKey.workspace(WorkspaceID(from)))" },
                                            report: describe)

            // Cmd-P, the chosen workspace's row, Enter.
            #expect(services.registry.perform("goToWorkspace"))
            let row = "workspace:\(to)"
            try await PinnedPageTests.until({ services.palette.model.rows.contains { $0.id == row } },
                                            report: { "Cmd-P lists \(services.palette.model.rows.map(\.id))" })
            services.palette.model.select(rowID: row)
            #expect(services.palette.model.handle(.submit))

            try await PinnedPageTests.until({ window.state.workspaceID == to }, report: describe)
            #expect(model.selectedItem == .workspace(WorkspaceID(to)), "\(describe())")
            #expect(SidebarCmdNumberTwiceTests.drawnSelection(view) == "row:\(SidebarRowKey.workspace(WorkspaceID(to)))", "\(describe())")
        }
    }
}
