import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46926: `/side` (and Fork to the Right) from a chat in the agent chat
/// dock, with a column already on the dock's right, showed the side chat for a moment and then its pane vanished.
/// The app asked the daemon for a split right of the chat's pane; the daemon refuses every new pane in the agent chat
/// dock but Split Down (`dock-column-agent-chat`), so the stand-in pane went with the refused creation while the fork
/// itself lived on in acpmux. A split right of a docked chat now opens as a new strip column right of the dock.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChatDockSideChatSplitTests {
    @Test func aSplitRightOfADockedChatOpensInANewColumnBesideTheDock() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let chatPane = try #require(content.focusedPane ?? content.panes.values.first)
            if services.agentTabs.localHost == nil { services.agentTabs.localHost = "install:chat-dock-side-chat" }
            // The chat: an agent tab in the pane that becomes the dock.
            let chat = try await services.agentTabs.open(in: chatPane.pane.handle, of: chatPane.daemon).value().key
            // The reported layout: the chat's column docked left with the agent chat role, a column on its right.
            _ = try await connection.newColumn(rightOf: chatPane.pane.handle)
            try await connection.setColumnDock(of: chatPane.pane.handle, dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat))
            @MainActor func dock() -> LayoutColumn? {
                content.layoutModel.screen(containing: chatPane.layoutPaneID)?.layout.columns.first { $0.dock?.role == .agentChat }
            }
            @MainActor func strip() -> [LayoutColumn] {
                content.layoutModel.screen(containing: chatPane.layoutPaneID)?.layout.columns.filter { $0.dock == nil } ?? []
            }
            try await PinnedPageTests.until({ dock()?.root.panes == [chatPane.layoutPaneID] && strip().count == 1 }, report: {
                "dock \(String(describing: dock())), strip \(strip().count) column(s)"
            })
            #expect(content.layoutModel.screen(containing: chatPane.layoutPaneID)?.inAgentChatDock(chatPane.layoutPaneID) == true)

            // `/side`'s open: a split right of the chat (AgentSidePanes -> openOnRight(splitRight:) -> openBeside).
            var landed: String?, moved: Bool?
            let opened = services.agentTabs.openBeside(chat, split: true, direction: "right",
                                                       open: { pane, daemon, split in try services.agentTabs.open(in: pane, of: daemon, split: split) },
                                                       created: { landed = $0 }, finished: { moved = $0 })
            #expect(opened, "the side chat's open was refused at once")
            try await PinnedPageTests.until({ moved != nil }, report: { "the side chat's open never finished; landed \(String(describing: landed))" })
            #expect(moved == true, "the side chat never left the chat's pane")
            let tab = try #require(landed, "no tab landed for the side chat")
            let pane = try #require(content.panes.values.first { $0.pane.tabs.contains { $0.id == tab } }?.layoutPaneID,
                                    "the side chat's tab vanished")
            #expect(dock()?.root.panes == [chatPane.layoutPaneID], "the dock still holds only the chat")
            #expect(strip().count == 2, "the side chat opened in a new strip column")
            // A docked chat has no strip column of its own, so the new column goes where Fork to New Column Right puts
            // it (`ForkColumnSlot`: after the strip's last column), not into the column already there.
            #expect(strip().last?.root.panes.contains(pane) == true, "the side chat is in its own new column")
        }
    }
}
