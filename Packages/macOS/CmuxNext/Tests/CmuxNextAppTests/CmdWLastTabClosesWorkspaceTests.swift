import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
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
    @Test func cmdWOnTheLastTabClosesTheWorkspaceInThePressTurn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let first = try #require(store.workspaces.first).id
            // A second workspace (Cmd-N), shown, with its one pane and one tab.
            #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({
                store.workspaces.count == 2 && services.windows.active?.state.workspaceID != first
                    && (services.windows.active?.workspaceContent?.focusedPane?.orderedIDs.count ?? 0) == 1
            }, report: { "workspaces \(store.workspaces.count), shown \(String(describing: services.windows.active?.state.workspaceID))" })
            let window = try #require(services.windows.active)
            let closing = try #require(window.state.workspaceID)
            let content = try #require(window.workspaceContent)
            try #require(content.layoutModel.screens.reduce(0) { $0 + $1.layout.panes.count } == 1,
                         "the new workspace shows more than one pane")

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            // The press's turn: the workspace closes as Close Workspace closes it.
            #expect(ClosingWorkspaces.shared.ids.contains(closing), "Cmd-W on the last tab did not close its workspace in its turn")
            #expect(window.state.workspaceID != closing, "the window still shows the closing workspace")

            try await PinnedPageTests.until({ store.workspaces.allSatisfy { $0.id != closing } }, report: { "the workspace was not closed" })
            #expect(services.windows.active === window, "the window closed with the workspace")
            #expect(store.workspaces.contains { $0.id == first }, "the other workspace closed too")
        }
    }
}
