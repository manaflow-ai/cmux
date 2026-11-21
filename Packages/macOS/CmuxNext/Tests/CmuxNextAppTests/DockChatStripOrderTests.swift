import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-03: "the browser/tab opening animation still plays on the main pane before going".
/// A lone chat's link is made in the chat's pane; the chat docks left and the pane, holding the link's
/// tab, becomes the column on its right (``MainPaneLayout``). The dock's wait for the moved chat hears
/// the store before the pane's own observation does, and its strip sync (``OutboundTab/finish(moved:)``)
/// must not show the tab while the layout still has the pane full width as the main pane: the strip
/// lists the tab only once the layout has the dock beside it (`PaneController.layoutFirst`).
@MainActor @Suite(.serialized, .closesItsWindows) struct DockChatStripOrderTests {
    private static let source = PaneID(rawValue: 1), dock = PaneID(rawValue: 2)
    private static let chat = SurfaceID(rawValue: 1), link = SurfaceID(rawValue: 2)

    /// The chat's screen: its pane alone holding `tabs`, or with `docked` the chat in a left dock and
    /// the source pane on its right holding the link.
    private static func tree(_ tabs: [SurfaceID], docked: Bool = false) -> DaemonTree {
        func pane(_ id: PaneID, _ surfaces: [SurfaceID]) -> PaneSnapshot {
            PaneSnapshot(id: id, tabs: surfaces.map { TabSnapshot(surface: $0, title: "~") })
        }
        let screen: ScreenSnapshot
        if docked {
            let role = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
            screen = ScreenSnapshot(id: 1, layout: .leaf(source),
                                    columns: [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(dock), dock: role),
                                              ColumnSnapshot(id: 11, width: 1, layout: .leaf(source))],
                                    panes: [pane(source, [link]), pane(dock, [chat])])
        } else {
            screen = ScreenSnapshot(id: 1, layout: .leaf(source), columns: [ColumnSnapshot(id: 11, width: 1, layout: .leaf(source))],
                                    panes: [pane(source, tabs)])
        }
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    @Test func aDockedChatsLinkShowsInItsStripOnlyOnceTheLayoutHasTheDock() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let identity = DaemonIdentity(capabilities: [DaemonCapability.dockColumns.rawValue, DaemonCapability.dockColumnRole.rawValue],
                                      generation: DaemonGeneration(rawValue: "dock-chat-strip-order"))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree([Self.chat]))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime((services, state)) { content.teardown(); window.closeAfterTest() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        let pane = try #require(content.panes.values.first { $0.pane.handle == Self.source })
        func listed() -> [SurfaceID] {
            pane.stripModel.tabs.compactMap { item in pane.pane.tabs.first { $0.id == item.id.rawValue }?.surface }
        }
        func panes() -> Int { content.layoutModel.screens.first?.layout.panes.count ?? 0 }

        // The link's tab is made in the chat's pane, unselected, and held while the chat is there.
        let outbound = OutboundTab.begin(in: pane)
        store.apply(snapshot: Self.tree([Self.chat, Self.link]))
        outbound.made(Self.link)
        let chat = try #require(pane.pane.tabs.first { $0.surface == Self.chat })
        outbound.hidden(whileHolding: chat.id)
        pane.syncStripFromStore()
        #expect(listed() == [Self.chat], "the link's tab opened over the lone chat")
        #expect(panes() == 1)

        // The chat docks. Before any observation step, the dock's wait hears it and ends the hold.
        store.apply(snapshot: Self.tree([], docked: true))
        outbound.finish(moved: true)
        if listed().contains(Self.link) {
            #expect(panes() == 2, "the link's tab showed in the main pane's strip before the layout docked the chat")
        }
        pane.syncStripFromStore()
        #expect(listed() == [Self.link])
        #expect(panes() == 2)
    }
}
