import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// ``LinkOpener/target(from:cmdClick:mainPane:chatLink:)`` for a web link from an agent chat, on a
/// real workspace: an agent chat split beside a terminal (Leo 2026-10-21: "WHY DID THIS NOT OPEN TO
/// THE SIDE?", "open on right by default"). On the right by default; Tab in the Same Pane keeps it in
/// the chat's pane; a zoomed chat opens a new split rather than a tab in the pane its zoom hides.
@MainActor struct LinkOpenerChatLinkTests {
    private static func tree(zoomed: Bool) -> DaemonTree {
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: "chat-1", harness: "codex"))
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), zoomedPane: zoomed ? first.id : nil, layout: layout, panes: [first, second])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"link-opener-chat-link-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The chat | terminal workspace shown in a borderless window, laid out.
    private static func shown(zoomed: Bool = false) throws -> (AppServices, NSWindow, WorkspaceContentController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(zoomed: zoomed))
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

    /// The chat's pane and the terminal's, by the surface each shows.
    private static func panes(_ content: WorkspaceContentController) throws -> (chat: PaneController, terminal: PaneController?) {
        let controllers = Array(content.panes.values)
        let chat = try #require(controllers.first { $0.selectedTab?.surface == SurfaceID(rawValue: 1) }, "the chat's pane is not shown")
        return (chat, controllers.first { $0.selectedTab?.surface == SurfaceID(rawValue: 2) })
    }

    @Test(arguments: [LinkPlacement.splitRight, .newColumn])
    func aChatLinkOpensInThePaneOnItsRight(_ placement: LinkPlacement) throws {
        let (services, window, content) = try Self.shown()
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, terminal) = try Self.panes(content)
        let right = try #require(terminal)
        services.linkOpener.placement = { placement }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .pane(right.layoutPaneID))
        // The terminal shows no chat: its links keep the rules for any pane.
        #expect(services.linkOpener.chatLinkTarget(from: right) == nil)
    }

    @Test func tabInTheSamePaneKeepsAChatLinkInTheChatsPane() throws {
        let (services, window, content) = try Self.shown()
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { .samePane }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .pane(chat.layoutPaneID))
    }

    /// The zoomed chat hides the terminal: the link opens a new split on its right (which ends the
    /// zoom), never a tab in the hidden terminal.
    @Test func aZoomedChatLinkOpensANewSplitNotTheHiddenPane() throws {
        let (services, window, content) = try Self.shown(zoomed: true)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        let (chat, _) = try Self.panes(content)
        services.linkOpener.placement = { .splitRight }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .splitRight(of: chat.layoutPaneID))
        services.linkOpener.placement = { .newColumn }
        #expect(services.linkOpener.target(from: chat, chatLink: true) == .newColumn(rightOf: chat.layoutPaneID))
    }
}
