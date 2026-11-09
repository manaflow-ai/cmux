import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence, cmux-ad m48 (2026-11-06): "if we're closing the last tab in a workspace, the entire workspace should just
/// immediately close." The close picks one kind at the close (`TabCloseKind`) and never mixes them. The last tab of the
/// last pane closed the tab first (its strip emptied, the empty workspace showed), then `EmptyWorkspaceRepair` asked
/// the daemon for its terminals and closed the workspace several round trips later. Now that close is Close
/// Workspace's own: the row leaves and the window shows the next workspace in the close's turn, and nothing inside the
/// closing workspace changes (no strip or pane motion, no repair).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct LastTabClosesWorkspaceTests {
    @Test func theKindIsChosenOnceFromThePanesTheCloseLeaves() {
        #expect(TabCloseKind(panes: [(true, false), (false, false)], home: false) == .tabs)
        #expect(TabCloseKind(panes: [(true, true), (false, false)], home: false) == .panes)
        #expect(TabCloseKind(panes: [(true, true)], home: false) == .workspace)
        #expect(TabCloseKind(panes: [(true, true), (true, true), (false, true)], home: false) == .workspace)
        #expect(TabCloseKind(panes: [(true, true)], home: true) == .panes, "a Home workspace closed with its tabs")
    }

    /// The CLI's and the socket's close of the last tab (`action.run closeTab tab:<id>`): in the close's own turn the row
    /// is leaving, the window shows another workspace, and the closing tab is still in its strip (nothing in the
    /// closing workspace changed); the workspace then leaves the daemon without the repair closing it.
    @Test func aScriptedCloseOfTheLastTabClosesTheWorkspaceInItsTurn() async throws {
        try await Self.withLastTab { s in
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: s.tab.rawValue), origin: .cli)))
            #expect(ClosingWorkspaces.shared.ids.contains(s.id), "the row did not start leaving in the close's turn")
            #expect(s.controller.state.workspaceID != s.id, "the window still shows the closing workspace after the close's turn")
            #expect(s.pane.orderedIDs.contains(s.tab), "the closing workspace's strip changed (a tab close ran inside it)")
            #expect(s.pane.workspace?.layoutModel.isClosing(s.pane.layoutPaneID) != true, "a pane close ran inside the closing workspace")
            try await Self.closes(s)
        }
    }

    /// A person's Cmd-W on the last idle terminal of a workspace: the workspace closes through Close Workspace (its row
    /// leaves, the next workspace shows), never through the empty-workspace repair.
    @Test func cmdWOnTheLastTabClosesTheWorkspace() async throws {
        try await Self.withLastTab { s in
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ s.controller.state.workspaceID != s.id }, within: .seconds(10),
                                            report: { "the window still shows the closing workspace" })
            try await Self.closes(s)
        }
    }

    // MARK: Fixture

    private struct LastTab {
        let services: AppServices
        let controller: WindowController
        let id: String
        let key: WorkspaceKey
        let pane: PaneController
        let tab: CmuxNextTabs.TabID
    }

    /// A second workspace, shown, with one pane and one idle terminal, its pane focused.
    private static func withLastTab(_ body: (LastTab) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(name: "last-tab"), into: controller.state.id)
            @MainActor func pane() -> PaneController? {
                services.workspace(id: id)?.screens.first?.panes.first.flatMap(services.paneController(for:))
            }
            try await PinnedPageTests.until({
                if controller.state.workspaceID != id { services.windows.show(workspaceID: id, in: controller.state) }
                return controller.state.workspaceID == id && pane()?.orderedIDs.count == 1 && controller.sidebar.model.selectableWorkspaces.count > 1
            }, within: .seconds(60), report: { "the new workspace never showed its one terminal" })
            let pane = try #require(pane())
            pane.workspace?.layoutModel.focus(pane.layoutPaneID, notify: false)
            PaneHandlers.focus(pane.layoutPaneID, in: try #require(pane.workspace))
            try await PinnedPageTests.until({ services.windows.active?.focusedPane === pane }, report: { "the pane never took the focus" })
            try await body(LastTab(services: services, controller: controller, id: id, key: try #require(services.workspace(id: id)?.key), pane: pane, tab: try #require(pane.orderedIDs.first)))
        }
    }

    /// The workspace left the daemon, the window shows another, and the repair never had to close it.
    private static func closes(_ s: LastTab) async throws {
        try await PinnedPageTests.until({ s.services.workspace(id: s.id) == nil }, within: .seconds(20), report: { "the workspace never closed" })
        #expect(s.controller.state.workspaceID != s.id)
        #expect(!s.services.emptyWorkspaces.decisions.contains { $0.key == s.key }, "the empty-workspace repair closed it, not the close")
    }
}
