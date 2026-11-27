import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// 2026-11-15, Settings opens late: Cmd-, on a fresh launch (Home's pinned dock alone, focused) made
/// the Settings tab in the dock, hidden (OutboundTab), waited for `new-conversation-tab`'s reply, then
/// moved it to a new column (`move-tab-to-column`): two daemon round trips, 40-100 ms on
/// cmux-lawrence-2, before the tab showed at all. A link or browser tab from the lone dock opens in its
/// split in one commit since #33548; a page tab now does the same (`conversation-tab-split-v1`): its
/// column and tab show in the key's turn, and the dock never lists it.
@MainActor struct PageTabFromHomesLoneDockTests {
    private final class Page: InternalPageProvider {
        let page = InternalPageID.settings
        var title = "Settings"
        var symbol = "gear"
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// Home's pinned dock (pane 1, taking tabs) alone on its screen.
    private static func homeDockAlone() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, title: "Home")])
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true, allowsTabs: true)
        let column = ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(PaneID(rawValue: 1)), dock: dock)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), columns: [column], panes: [pane])
        var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "Home", screens: [screen])
        workspace.kind = "home"
        return DaemonTree(workspaces: [workspace])
    }

    @Test(.timeLimit(.minutes(1))) func aPageFromHomesLoneDockShowsInItsColumnAtOnce() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let capabilities: [DaemonCapability] = [.conversationTabs, .pageTabs, .conversationTabSplit, .splitClientKeys,
                                                .splitClientSplitID, .pinnedDock, .pinnedDockAlone]
        let list = capabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"page-split","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.homeDockAlone())
        services.pages.register(Page())
        let (asked, ask) = AsyncStream<ConversationTabSplit?>.makeStream()
        services.pages.createStoreTab = { _, _, _, _, _, split in
            ask.yield(split)
            throw CancellationError()
        }
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer { window.teardown(); window.window?.close() }
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: window.state)
        defer { pane.teardown() }
        #expect(HomeDockOpens.opensBeside(model, services: services))
        #expect(store.isLonePinnedDock(model.handle))

        #expect(services.pages.openStoreTab(.settings, in: model, of: services.daemon, services: services, controller: pane,
                                            window: window, focus: true) != nil)

        let intent = try #require(store.pendingIntents.first)
        guard case .splitPane(let target, let direction, _, let provisional) = intent else {
            Issue.record("Settings from Home's dock was made in the dock, to be moved after the reply: \(intent)")
            return
        }
        #expect(target == PaneID(rawValue: 1))
        #expect(direction == .right)
        #expect(provisional.tab?.conversation?.page == InternalPageID.settings.rawValue)
        #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)], "the Settings tab showed in Home's dock")
        var requests = asked.makeAsyncIterator()
        let sent = await requests.next()
        #expect(sent??.direction == .right, "new-conversation-tab went to the dock, not its new column")
        #expect(sent??.paneID == provisional.paneID, "the daemon's pane would not replace the column shown")
    }
}
