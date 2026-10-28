import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-28 (handoff/motion-cascade.md): "cmd w on last tab in workspace should have better close animation
/// (should just be same as cmd shift w animation, not animate closing the tab first, then the workspace)". One intent,
/// one animation: a Cmd-W that empties the workspace's only pane is that workspace's close, from the press's turn, as
/// Close Workspace (Cmd-Shift-W) does it: its row leaves the sidebar, the selection moves and the window shows the
/// next workspace in that turn. Before, the tab went, an empty pane stayed for a daemon round trip, and the workspace
/// left about three round trips later through the empty-workspace repair. Runs against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWLastTabClosesWorkspaceTests {
    /// A second workspace whose one pane holds one tab, whatever Cmd-N opens on this Mac (a terminal or the New Tab
    /// page), shown in the active window.
    static func secondWorkspace(_ services: AppServices) async throws -> (window: WindowController, workspace: String, first: String) {
        let store = services.daemon.store
        let first = try #require(store.workspaces.first).id
        #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
        try await PinnedPageTests.until({
            store.workspaces.count == 2 && services.windows.active?.state.workspaceID != first
                && (services.windows.active?.workspaceContent?.focusedPane?.orderedIDs.count ?? 0) == 1
        }, report: { "workspaces \(store.workspaces.count), shown \(String(describing: services.windows.active?.state.workspaceID))" })
        let window = try #require(services.windows.active)
        let content = try #require(window.workspaceContent)
        try #require(content.layoutModel.screens.reduce(0) { $0 + $1.layout.panes.count } == 1, "the new workspace shows more than one pane")
        return (window, try #require(window.state.workspaceID), first)
    }

    @Test func cmdWOnTheLastTabClosesTheWorkspaceInThePressTurn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let (window, closing, first) = try await Self.secondWorkspace(services)

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            // The press's turn: the workspace closes as Close Workspace closes it.
            #expect(ClosingWorkspaces.shared.ids.contains(closing), "Cmd-W on the last tab did not close its workspace in its turn")
            #expect(window.state.workspaceID != closing, "the window still shows the closing workspace")

            try await PinnedPageTests.until({ store.workspaces.allSatisfy { $0.id != closing } }, report: { "the workspace was not closed" })
            #expect(services.windows.active === window, "the window closed with the workspace")
            #expect(store.workspaces.contains { $0.id == first }, "the other workspace closed too")
        }
    }

    /// Close Workspace asks what the tab close of its terminals would ask: an agent at work in one, with
    /// `app.warnBeforeClosingAgentSession` (its default, on), so Cmd-W through the workspace close loses no question
    /// (review of 5141e93507e). The same holds for Cmd-Shift-W.
    @Test func closeWorkspaceAsksAboutAWorkingAgentAsTheTabCloseDoes() async throws {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])]))
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        try #require(tab.kind == .pty && !tab.dead, "the fixture's tab is not a live terminal")
        tab.agent = AgentStatus(surface: 1, state: .working, agent: "claude")
        let services = AppServices(environment: AppEnvironment.current([:]))
        let prompt = await WorkspaceBulkClose.prompt([(workspace, services.daemon)], warn: false, warnAgent: true)
        #expect(prompt?.suppresses == CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath, "no agent question: \(String(describing: prompt))")
        #expect(await WorkspaceBulkClose.prompt([(workspace, services.daemon)], warn: false, warnAgent: false) == nil)
    }
}
