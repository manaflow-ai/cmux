import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSidebar
import Foundation
import Testing

/// Every entrypoint of Close Workspace runs the one close (Lawrence f15/f16, WORKSPACE CLOSE part B "one path"). The
/// command palette's workspace row has its own "Close Workspace" command; it sent `close-workspace` to the daemon
/// itself: no `WorkspaceCloseFlow`, so the row and the window's selection waited for the daemon's echo, a running
/// program was not asked about, and a second close of the same workspace was not held back. It now runs the
/// `closeWorkspace` action for that row, as the sidebar row's close button does.
///
/// A real session daemon (the same-tree cmux-tui): `PinnedPageTests.withApp` requires its binary, so a run without it
/// fails; it is never skipped.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)))
struct PaletteWorkspaceCloseTests {
    @Test func thePaletteRowsCloseRunsCloseWorkspace() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(name: "palette-close"), into: controller.state.id)
            try await PinnedPageTests.until({
                if controller.state.workspaceID != id { services.windows.show(workspaceID: id, in: controller.state) }
                let terminals = services.workspace(id: id)?.screens.first?.panes.first.flatMap(services.paneController(for:))?.orderedIDs.count
                return controller.state.workspaceID == id && terminals == 1 && controller.sidebar.model.selectableWorkspaces.count > 1
            }, within: .seconds(60), report: { "the new workspace never showed its one terminal" })
            try #require(!WorkspaceCloseFlow.running.contains(id), "fixture: a close of the new workspace runs already")

            PaletteSourcesBridge.WorkspaceSource(services: services).closeWorkspace(id: id)

            // In the command's own turn the one close has it (`WorkspaceCloseFlow.start`): a second press sends nothing.
            #expect(WorkspaceCloseFlow.running.contains(id), "the palette row's Close Workspace did not start Close Workspace's flow")
            try await PinnedPageTests.until({ services.workspace(id: id) == nil }, within: .seconds(30), report: { "the workspace never closed" })
            #expect(controller.state.workspaceID != id, "the window still shows the closed workspace")
            try await PinnedPageTests.until({ !WorkspaceCloseFlow.running.contains(id) && !ClosingWorkspaces.shared.ids.contains(id) },
                                            within: .seconds(20), report: { "the close never ended" })
        }
    }
}
