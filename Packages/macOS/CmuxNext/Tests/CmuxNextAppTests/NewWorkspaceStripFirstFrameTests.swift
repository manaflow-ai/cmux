import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Perceived speed (#20516): a new workspace's lone agent chat painted its first frame with a tab
/// strip, and the strip went away a turn later, moving the whole page up by its height. The pane
/// applied its first state before it knew its workspace, and the chat's no-strip rule
/// (``ChatDockChrome``) reads the workspace's layout. The first frame is now the settled one.
@MainActor struct NewWorkspaceStripFirstFrameTests {
    private static func tree() -> DaemonTree {
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: "s-chat", harness: "claude"))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat])
        // One viewport column, as the daemon reports a new workspace's screen (`viewport-splits-v1`).
        let column = ColumnSnapshot(id: 10, width: 1, layout: .leaf(PaneID(rawValue: 1)))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), columns: [column], panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"strip-first-frame-test","generation":"g1","capabilities":["dock-column-role-v1"]}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func aNewWorkspacesLoneChatMountsWithoutItsStrip() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { content.teardown() }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()

        // What the first committed frame shows: no observation turn has run yet.
        let pane = try #require(content.paneController(key: workspace.screens[0].panes[0].id))
        let first = pane.view.hidesStrip
        // The settled state, after the pane's own observation has run.
        try await Task.sleep(for: .milliseconds(300))
        // Each input of the chat's no-strip rule, so a fixture that never hides the strip says why.
        #expect(services.daemon.supports(DaemonCapabilities.shared.dockColumnRole))
        #expect(content.layoutModel.screen(containing: pane.layoutPaneID)?.layout.columns.count == 1)
        #expect(pane.tabBarKind == .agent)
        #expect(services.paneTabBars.choice(for: pane.paneKey) == nil)
        #expect(ChatDockChrome.hidesStrip(pane, tabCount: 1))
        #expect(pane.view.hidesStrip)
        #expect(first == pane.view.hidesStrip, "the lone chat mounted with a tab strip that a later turn removes")
    }
}
