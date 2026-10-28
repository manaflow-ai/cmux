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
/// left about three round trips later through the empty-workspace repair. The workspace's one tab is a New Tab page,
/// whose close nothing can hold back (a live terminal can ask, `TabCloseGuard.closeWorkspaceIfEmptied`). Runs against a same-tree
/// cmux-tui daemon.
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

    /// A last tab whose close can ask (a live terminal: a running program or a working agent) keeps the tab close, which
    /// asks first: the route never closes a workspace past a question (review of eccfca50aa5).
    @Test func aLiveTerminalLastTabKeepsTheTabClose() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let terminal = try await connection.newTab(in: model.handle)
            try await PinnedPageTests.until({ store.tab(surface: terminal.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            for id in pane.orderedIDs where store.tab(id: id.rawValue)?.surface != terminal.surface {
                if let tab = store.tab(id: id.rawValue) { try await connection.closeTab(tab.surface) }
            }
            try await PinnedPageTests.until({ pane.orderedIDs.count == 1 }, report: { "the pane holds \(pane.orderedIDs)" })
            let id = try #require(pane.orderedIDs.first)
            let workspace = try #require(pane.workspace?.workspace.id)
            #expect(!TabCloseGuard.closeWorkspaceIfEmptied(AppActionContext(services: services), emptying: pane, closing: [id],
                                                           by: .init(time: 1, isKey: true, isRepeat: false)),
                    "a live terminal's close went past its question")
            #expect(!ClosingWorkspaces.shared.ids.contains(workspace))
        }
    }
}
