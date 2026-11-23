import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/49625: with an agent chat alone on its screen, Shift-Cmd-L opened the
/// new browser as what looked like a split on the right. A person's new tab from a lone chat docked the chat in a new
/// left column (ChatColumnPlacement `.dockChat`) and left the browser in the chat's old pane. The rule: New Browser
/// Tab (Shift-Cmd-L, the menu bar, the palette) is a tab in the chat's own pane; only the chat header's Browser
/// button opens a browser on the chat's right. Runs the app's actions against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabFromALoneChatTests {
    /// One agent chat alone in the window's one pane, focused.
    private struct LoneChat {
        let store: DaemonStore
        let content: WorkspaceContentController
        let pane: PaneController
        let chatID: String

        /// The panes of the chat's workspace.
        var panes: [PaneModel] { store.workspaces.flatMap(\.screens).flatMap(\.panes) }
        /// The pane holding the chat now.
        var chatPane: PaneModel? { panes.first { $0.tabs.contains { $0.id == chatID } } }
        /// The first browser tab the daemon made (not a stand-in), and its pane.
        var browser: (tab: TabModel, pane: PaneModel)? {
            for pane in panes { if let tab = pane.tabs.first(where: { $0.kind == .browser && !ProvisionalTab.isProvisional($0.id) }) { return (tab, pane) } }
            return nil
        }

        func describe() -> String {
            panes.map { pane in "\(pane.id): [" + pane.tabs.map { "\($0.kind) \($0.id)" }.joined(separator: ", ") + "]" }.joined(separator: "; ")
        }
    }

    private static func loneChat(_ services: AppServices, _ connection: DaemonConnection, session: String) async throws -> LoneChat {
        let store = services.daemon.store
        let content = try #require(services.windows.active?.workspaceContent)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(services.paneController(for: model))
        let terminal = try #require(model.tabs.first?.surface)
        let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-lone-chat-browser"), hostName: "This Mac",
                                     session: session, harness: "claude")
        let chat = try await connection.request(NewConversationTabRequest(agentSession: record, pane: model.handle))
        try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.surface == chat.surface } })
        try await connection.closeTab(terminal)
        try await PinnedPageTests.until({ pane.pane.tabs.count == 1 && pane.pane.tabs.first?.surface == chat.surface })
        let chatID = try #require(pane.pane.tabs.first?.id)
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PinnedPageTests.until({ content.focusedPane === pane })
        // The case of the report: a person's new tab here would dock the chat.
        #expect(ChatColumnPlacement.resolve(from: pane, services: services) == .dockChat)
        return LoneChat(store: store, content: content, pane: pane, chatID: chatID)
    }

    /// Shift-Cmd-L (no target), the palette's or a tab menu's New Browser Tab (the chat's tab as target) and the pane
    /// toolbar's globe (the pane as target): a new browser tab next to the chat in its own pane. The chat does not dock
    /// and no pane opens on its right.
    @Test(arguments: ["key", "tab", "pane"])
    func newBrowserTabInALoneChatOpensATabInTheChatsPane(_ via: String) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let lone = try await Self.loneChat(services, connection, session: "chat-lone-new-browser-\(via)")
            let target: ActionTargetRef? = switch via {
            case "tab": ActionTargetRef(kind: .tab, id: lone.chatID)
            case "pane": ActionTargetRef(kind: .pane, id: lone.pane.paneKey)
            default: nil
            }
            #expect(services.registry.perform("openBrowser", invocation: ActionInvocation(target: target, origin: .user)))
            // Docking makes the browser in the same daemon commit that moves the chat out, so the first read with the
            // browser decides.
            try await PinnedPageTests.until({ lone.browser != nil }, report: { "no browser tab (\(via)): \(lone.describe())" })
            let browser = try #require(lone.browser)
            #expect(browser.pane === lone.pane.pane, "the browser opened in another pane (\(via)): \(lone.describe())")
            #expect(lone.chatPane === lone.pane.pane, "the chat left its pane (docked, \(via)): \(lone.describe())")
            #expect(lone.panes.count == 1, "a pane opened beside the chat (\(via)): \(lone.describe())")
        }
    }

    /// The chat header's Browser button keeps opening the browser on the chat's right: a pane other than the chat's,
    /// which holds only the chat. For a lone chat the header's tool placement declines and Split Browser Right runs (a
    /// guard that the fix above leaves the header's path alone). The header goes through its tool placement first, as AgentTabs+Header wires it.
    @Test func theHeadersBrowserButtonOpensOnTheChatsRight() async throws {
        try await PinnedPageTests.withApp { services, connection in
            // Wide enough for a split beside the chat (RightColumnPlacement.minimumChatWidth on each side).
            try #require(services.windows.active?.window).setFrame(NSRect(x: 0, y: 0, width: 1500, height: 800), display: true)
            let lone = try await Self.loneChat(services, connection, session: "chat-lone-header-browser")
            let splits = 2 * RightColumnPlacement.minimumChatWidth
            try await PinnedPageTests.until({ (LinkOpener.width(of: lone.pane) ?? 0) >= splits },
                                            report: { "the chat's pane is not \(Int(splits)) pt wide" })
            let tabs = services.agentTabs
            let actions = AgentChatTabActions(tab: { lone.chatID }, registry: { services.registry },
                                              openTool: { kind, cwd in tabs.openToolScoped?(tabs.tabKey(lone.chatID), kind, cwd) ?? false })
            actions.run("splitBrowserRight", cwd: nil)
            try await PinnedPageTests.until({ lone.browser.map { $0.pane !== lone.chatPane } == true },
                                            report: { "the header's Browser opened no browser beside the chat: \(lone.describe())" })
            #expect(lone.panes.count == 2, "\(lone.describe())")
            #expect(lone.chatPane?.tabs.map(\.id) == [lone.chatID], "the chat's pane holds more than the chat: \(lone.describe())")
        }
    }
}
