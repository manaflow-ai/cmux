import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/29848: in a workspace with the agent chat docked left and a pane
/// on its right (`layout.dockColumnMode = docked`), Cmd-Shift-D with the chat focused made no pane below it: the
/// one tool-split rule sent every person's split from the chat dock to the strip as a tab, and the daemon refused
/// any new pane in the dock. Split Down now splits below the focused pane in the dock, as classic cmux's
/// Cmd-Shift-D does; the chat stays the dock's top pane, and the pane on the right is untouched.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChatDockSplitDownTests {
    @Test func splitDownFromTheChatDockSplitsBelowTheFocusedPane() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let chat = try #require(content.focusedPane ?? content.panes.values.first)
            // The reported layout: the chat's column docked left with the agent chat role, a pane on its right.
            _ = try await connection.newColumn(rightOf: chat.pane.handle)
            try await connection.setColumnDock(of: chat.pane.handle, dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat))
            @MainActor func dock() -> LayoutColumn? {
                content.layoutModel.screen(containing: chat.layoutPaneID)?.layout.columns.first { $0.dock?.role == .agentChat }
            }
            @MainActor func strip() -> [LayoutColumn] {
                content.layoutModel.screen(containing: chat.layoutPaneID)?.layout.columns.filter { $0.dock == nil } ?? []
            }
            try await PinnedPageTests.until({ dock()?.root.panes == [chat.layoutPaneID] && strip().count == 1 }, report: {
                "dock \(String(describing: dock())), strip \(strip().count) column(s)"
            })
            let right = try #require(strip().first?.root.panes)
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { services.registry.refusalObserver = previous }

            // Cmd-Shift-D with the chat focused, as the key runs it.
            PaneHandlers.focus(chat.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === chat })
            #expect(services.registry.perform("splitDown", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ dock()?.root.panes.count == 2 }, report: {
                "the dock holds \(dock()?.root.panes ?? []) after Split Down; refusals \(refusals)"
            })
            #expect(refusals.isEmpty, "Split Down from the chat dock was refused: \(refusals)")
            #expect(dock()?.root.panes.first == chat.layoutPaneID, "the chat stays the dock's top pane")
            #expect(dock()?.dock?.role == .agentChat, "the column stays the chat dock")
            #expect(strip().first?.root.panes == right, "the pane on the right is untouched")
            let below = try #require(dock()?.root.panes.last)

            // Again from the pane below the chat: another pane below it, still in the dock.
            try await PinnedPageTests.until({ content.focusedPane?.layoutPaneID == below }, report: {
                "focused \(String(describing: content.focusedPane?.paneKey)), wanted the new pane below the chat"
            })
            #expect(services.registry.perform("splitDown", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ dock()?.root.panes.count == 3 }, report: {
                "the dock holds \(dock()?.root.panes ?? []) after a second Split Down; refusals \(refusals)"
            })
            #expect(refusals.isEmpty, "Split Down below the chat was refused: \(refusals)")
            #expect(dock()?.root.panes.prefix(2) == [chat.layoutPaneID, below], "each Split Down lands below the pane it split")
            #expect(strip().first?.root.panes == right, "the pane on the right is untouched")
        }
    }
}
