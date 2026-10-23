import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// Every tab strip the app makes draws from the composition root's one ``TabIconCaches``
/// (`AppServices.tabIconCaches`): each pane's strip and the workspace's screen bar. Before the
/// caches were injected they were process-wide, so a new pane, split or workspace found the icons
/// another strip had drawn; a strip with its own caches would draw every icon again on the main
/// thread for each new pane and after each theme or tint change, and hold its own copies.
@MainActor @Suite(.serialized) struct TabIconCachesSharingTests {
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"tab-icon-caches-sharing-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func stripModel() -> TabStripModel {
        TabStripModel(tabs: [
            TabItem(id: TabID("term"), title: "zsh", icon: .icon(.terminal)),
            TabItem(id: TabID("agent"), title: "Claude", icon: .agentMark("claude")),
            TabItem(id: TabID("sym"), title: "Star", icon: .symbol("star.fill")),
        ], selectedID: TabID("term"))
    }

    @Test func everyPaneStripAndTheScreenBarDrawFromTheAppsOneInstance() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services,
                                                 state: WindowState(record: record))
        defer { content.teardown() }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()

        let keys = try #require(content.layoutModel.screens.first?.layout.panes)
        try #require(keys.count == 2, "the split did not mount two panes")
        for key in keys {
            let pane = try #require(content.paneController(key: key.rawValue))
            #expect(pane.view.stripView.iconCaches === services.tabIconCaches,
                    "a pane's strip made its own icon caches instead of taking the app's")
        }
        #expect(content.screenBar.view.iconCaches === services.tabIconCaches,
                "the screen bar made its own icon caches instead of taking the app's")
    }

    @Test func aSecondPaneOnTheSameCachesDrawsNoIconAgain() {
        let caches = TabIconCaches()
        let first = PaneContentView(stripModel: Self.stripModel(), iconCaches: caches, reveal: LaunchReveal(deadline: .zero))
        first.stripView.sync(fromModel: true, animating: false)
        let drawn = caches.entryCount
        #expect(drawn > 0, "the pane's strip drew its icons from somewhere other than the injected caches")

        let second = PaneContentView(stripModel: Self.stripModel(), iconCaches: caches, reveal: LaunchReveal(deadline: .zero))
        second.stripView.sync(fromModel: true, animating: false)
        #expect(second.stripView.iconCaches === first.stripView.iconCaches)
        #expect(caches.entryCount == drawn, "a second pane on the same caches drew its icons again")
    }
}
