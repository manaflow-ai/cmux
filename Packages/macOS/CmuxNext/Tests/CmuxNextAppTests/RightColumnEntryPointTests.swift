import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// The two entry points every open on the right goes through take their turn beside the source pane
/// (``RightColumnTurns``): ``LinkOpener/open(from:background:mainPane:_:)`` (links, files,
/// browser tabs, New Tab, the diff page; folders through ``LinkOpener/openFolder(_:from:)``) and
/// ``AgentTabStore/openOnRight(of:origin:open:created:finished:)`` (subagents, side chats, Session Info
/// sessions, transcript session cards). One asked for while another is under way waits, then decides.
@MainActor @Suite(.serialized, .closesItsWindows) struct RightColumnEntryPointTests {
    private static func tree() -> DaemonTree {
        let chat = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "chat")])
        let right = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "diff")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(chat.id), b: .leaf(right.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [chat, right])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    @Test func aLinkOpenWaitsForTheOpenUnderWayBesideItsPane() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self,
            from: Data(#"{"app":"cmux-tui","protocol":1,"session":"right-turn-test","generation":"g1"}"#.utf8))
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1600, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let panes = try #require(content.layoutModel.screens.first?.layout.panes)
        try #require(panes.count == 2)
        let chat = try #require(content.panes[panes[0]]), right = panes[1]
        services.linkOpener.placement = { .splitRight }

        // Another open (a subagent's, say) is still moving into place beside the chat.
        var underWay: (@MainActor () -> Void)?
        services.linkOpener.turns.serially(beside: chat.layoutPaneID) { done in underWay = done }
        var made: [LayoutPaneID] = []
        // The make refuses, so its turn ends at once and no daemon move is needed here.
        let answered = services.linkOpener.open(from: chat) { pane, placed in
            made.append(pane.layoutPaneID)
            return false
        }
        #expect(answered, "a waiting open answers true")
        #expect(made.isEmpty, "the link decided its place while another open was still moving in")
        underWay?()
        #expect(made == [right], "in its turn, the link opens by the pane on the right (a split below it is made there first)")
        #expect(!services.linkOpener.turns.isBusy(beside: chat.layoutPaneID), "a refused open kept its turn")
        withExtendedLifetime(state) {}
    }

    /// Review of the #28044 carry at 1eb458cf: a file a tab already shows is selected where it is and
    /// never reports to `placed`, so its turn held the source until the 30 s backstop and the next open waited.
    @Test func anOpenShownWhereItAlreadyWasEndsItsTurn() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self,
            from: Data(#"{"app":"cmux-tui","protocol":1,"session":"right-turn-inplace","generation":"g1"}"#.utf8))
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w2","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1600, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let panes = try #require(content.layoutModel.screens.first?.layout.panes)
        let chat = try #require(content.panes[panes[0]])
        services.linkOpener.placement = { .splitRight }
        var gotPlaced = false
        // One pane on the right: the open splits below it, so `make` gets `placed`, and shows an existing tab instead.
        let opened = services.linkOpener.open(from: chat) { _, placed in
            gotPlaced = placed != nil
            services.linkOpener.openedInPlace()
            return true
        }
        #expect(opened)
        #expect(gotPlaced, "fixture: the open was asked to place a new tab")
        #expect(!services.linkOpener.turns.isBusy(beside: chat.layoutPaneID), "a tab shown in place kept its turn")
        withExtendedLifetime(state) {}
    }

    @Test func anAgentOpenWaitsForTheOpenUnderWayBesideItsChat() {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        let source = LayoutPaneID("agent-turn-chat")
        let turns = RightColumnTurns()
        tabs.serially = { _, turn in turns.serially(beside: source, turn) }
        tabs.rightColumn = { _ in .init(sourceWidth: 1400) }
        var mainPane: [String] = []
        // Main pane layout is asked first (nothing on the right) and refuses, so the turn ends at once.
        tabs.openInMainPane = { chat, _, _, _, _ in mainPane.append(chat); return false }
        var underWay: (@MainActor () -> Void)?
        turns.serially(beside: source) { done in underWay = done }
        let answered = tabs.openOnRight(of: "chat-tab", open: { _, _ in throw CancellationError() })
        #expect(answered, "a waiting open answers true")
        #expect(mainPane.isEmpty, "the agent open decided its place while another open was still moving in")
        underWay?()
        #expect(mainPane == ["chat-tab"])
        #expect(!turns.isBusy(beside: source), "a refused open kept its turn")
    }
}
