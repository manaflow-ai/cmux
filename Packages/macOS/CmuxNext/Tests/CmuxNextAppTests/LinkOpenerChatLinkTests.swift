import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// ``LinkOpener/target(from:cmdClick:mainPane:chatLink:)`` for a web link from an agent chat, on a
/// real workspace (Leo 2026-10-21: "WHY DID THIS NOT OPEN TO THE SIDE?", "open on right by
/// default"). On the right by default; Tab in the Same Pane keeps it in the chat's pane; a zoomed
/// chat opens a new split rather than a tab in the pane its zoom hides; the chat dock, which never
/// splits, opens a new column; a machine whose daemon serves no browser tabs (a session-local tab,
/// which cannot be moved) keeps the rules for any page, so the tab still opens selected.
@MainActor struct LinkOpenerChatLinkTests {
    /// The chat's surface; every other pane shows `others`.
    private static let chatSurface = SurfaceID(rawValue: 1)

    private static func chat(_ surface: SurfaceID, session: String) -> TabSnapshot {
        var tab = TabSnapshot(surface: surface, kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: session, harness: "codex"))
        return tab
    }

    /// The layouts under test: pane 1 shows the chat, pane 2 a terminal or another chat.
    enum Shape {
        /// chat | terminal.
        case chatThenTerminal(zoomed: Bool)
        /// terminal | chat: nothing on the chat's right.
        case terminalThenChat
        /// The chat in the chat dock, another chat in the column on its right.
        case chatDockBesideAnotherChat
    }

    private static func tree(_ shape: Shape) -> DaemonTree {
        let chatPane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat(chatSurface, session: "chat-1")])
        let terminal = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let screen: ScreenSnapshot
        switch shape {
        case .chatThenTerminal(let zoomed):
            let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(chatPane.id), b: .leaf(terminal.id))
            screen = ScreenSnapshot(id: ScreenID(rawValue: 1), zoomedPane: zoomed ? chatPane.id : nil, layout: layout, panes: [chatPane, terminal])
        case .terminalThenChat:
            let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(terminal.id), b: .leaf(chatPane.id))
            screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [terminal, chatPane])
        case .chatDockBesideAnotherChat:
            let other = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [chat(SurfaceID(rawValue: 2), session: "chat-2")])
            let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
            let columns = [ColumnSnapshot(id: 10, width: 0.4, layout: .leaf(chatPane.id), dock: dock),
                           ColumnSnapshot(id: 11, width: 0.6, layout: .leaf(other.id))]
            screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(chatPane.id), columns: columns, panes: [chatPane, other])
        }
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"link-opener-chat-link-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The workspace shown in a borderless window, laid out. `servesTabs`: the daemon serves
    /// browser tabs (`frontend-browser-tabs-v1`), so a new tab can be moved.
    private static func shown(_ shape: Shape, servesTabs: Bool = true) throws -> (AppServices, NSWindow, WorkspaceContentController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.cache.browserTabs.serves = { _ in servesTabs }
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(shape))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        return (services, window, content)
    }

    /// The chat's pane and the other pane, by the surface each shows.
    private static func panes(_ content: WorkspaceContentController) throws -> (chat: PaneController, other: PaneController?) {
        let controllers = Array(content.panes.values)
        let chat = try #require(controllers.first { $0.selectedTab?.surface == Self.chatSurface }, "the chat's pane is not shown")
        return (chat, controllers.first { $0 !== chat })
    }

    @Test(arguments: [LinkPlacement.splitRight, .newColumn])
    func aChatLinkOpensInThePaneOnItsRight(_ placement: LinkPlacement) throws {
        let (services, window, content) = try Self.shown(.chatThenTerminal(zoomed: false))
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, terminal) = try Self.panes(content)
        let right = try #require(terminal)
        services.linkOpener.placement = { placement }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .pane(right.layoutPaneID))
        // The terminal shows no chat: its links keep the rules for any pane.
        #expect(services.linkOpener.chatLinkTarget(from: right) == nil)
    }

    @Test func tabInTheSamePaneKeepsAChatLinkInTheChatsPane() throws {
        let (services, window, content) = try Self.shown(.chatThenTerminal(zoomed: false))
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { .samePane }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .pane(chat.layoutPaneID))
    }

    /// The zoomed chat hides the terminal: the link opens a new split on its right (which ends the
    /// zoom), never a tab in the hidden terminal.
    @Test func aZoomedChatLinkOpensANewSplitNotTheHiddenPane() throws {
        let (services, window, content) = try Self.shown(.chatThenTerminal(zoomed: true))
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { .splitRight }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .splitRight(of: chat.layoutPaneID))
        services.linkOpener.placement = { .newColumn }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .newColumn(rightOf: chat.layoutPaneID))
    }

    /// The chat dock never splits (TabMoves refuses it, and the tab would stay over the chat): with
    /// only another chat on its right, the link opens a new column beside the dock.
    @Test(arguments: [LinkPlacement.splitRight, .newColumn])
    func fromTheChatDockWithOnlyChatsOnTheRightANewColumn(_ placement: LinkPlacement) throws {
        let (services, window, content) = try Self.shown(.chatDockBesideAnotherChat)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { placement }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .newColumn(rightOf: chat.layoutPaneID))
    }

    /// Nothing on the chat's right needs a new split; with no daemon browser tabs the session-local
    /// tab could not be moved there and would open unseen, so the link keeps the rules for any page.
    @Test func withoutDaemonBrowserTabsAChatLinkKeepsThePageRules() throws {
        do {
            let (services, window, content) = try Self.shown(.terminalThenChat)
            defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
            let (chat, _) = try Self.panes(content)
            #expect(services.linkOpener.target(from: chat, chatLink: true) == .splitRight(of: chat.layoutPaneID))
        }
        let (services, window, content) = try Self.shown(.terminalThenChat, servesTabs: false)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        #expect(services.linkOpener.chatLinkTarget(from: chat) == nil)
        #expect(services.linkOpener.target(from: chat, chatLink: true) == services.linkOpener.target(from: chat))
    }

    /// The real open on that machine: the session-local tab is made and selected, as before chat
    /// links went to the right, not left unselected in the chat's pane waiting for a move.
    @Test func withoutDaemonBrowserTabsAChatLinkOpensSelected() throws {
        let (services, window, content) = try Self.shown(.terminalThenChat, servesTabs: false)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { .splitRight }
        let url = try #require(URL(string: "https://example.com/pull/1"))
        #expect(services.linkOpener.openWeb(url, from: chat, background: false))
        let state = try #require(chat.state)
        let local = try #require(state.localBrowserTabs[chat.paneKey].first, "no session-local tab opened")
        #expect(chat.stripModel.selectedID == StripTabID(local.id))
    }
}
