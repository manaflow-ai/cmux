import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Perf-lead issue 11 (the create bench saw Cmd-I's new tab only in the first run of each phase,
/// 11 of 12 runs missed): Cmd-I docks its chat left (``DockedAgentChat``). The chat is hidden in
/// the pane it opened from until the dock takes it, under its provisional id and then the store's
/// (`PaneController.pendingDock`). When the dock answered, `dockFinished` dropped only the store's
/// id: it matched the provisional one through the provisional alias, which the store prunes once
/// its tab replaced the provisional one, before the move answers. The pane kept a chat "on its way
/// to its dock" forever, so once the person closed that chat (and its dock), every later Cmd-I in
/// the pane did nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewChatAfterItsDockClosedTests {
    @Test func cmdIOpensAChatAgainAfterTheDockedChatClosed() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-dock-closed")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let window = try #require(services.windows.active)
            let content = try #require(window.workspaceContent)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            /// The workspace's agent chats the store made (no provisional stand-in), with their panes.
            @MainActor func chats() -> [(tab: TabModel, pane: PaneModel)] {
                content.workspace.screens.flatMap(\.panes).flatMap { model in
                    model.tabs.filter { $0.conversation != nil && !ProvisionalTab.isProvisional($0.id) }.map { ($0, model) }
                }
            }
            @MainActor func describe() -> String {
                "chats \(chats().map { "\($0.tab.id)@\($0.pane.handle.rawValue)" }), pane \(pane.pane.handle.rawValue), "
                    + "focused \(String(describing: content.focusedPane?.pane.handle.rawValue)), on its way \(pane.pendingDock)"
            }
            try #require(chats().isEmpty, "the launch workspace holds no chat")

            // Cmd-I: the chat opens hidden here, docks left, and takes the focus there (after
            // the pane is told the dock answered: `dockFinished`, then `focusWhenShown`).
            #expect(services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({
                guard let chat = chats().first else { return false }
                return chat.pane !== pane.pane && content.focusedPane?.pane === chat.pane
            }, report: { describe() })
            let first = try #require(chats().first)

            // The person closes the chat; its dock goes with its one tab.
            try await connection.closeTab(first.tab.surface)
            try await PasswordManagerRouteTests.until({ store.tab(id: first.tab.id) == nil && chats().isEmpty }, report: { describe() })
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({ content.focusedPane === pane }, report: { describe() })

            // Cmd-I again opens a new chat.
            #expect(services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ chats().contains { $0.tab.id != first.tab.id } },
                                                     report: { "the second Cmd-I opened no chat: " + describe() })
        }
    }
}
