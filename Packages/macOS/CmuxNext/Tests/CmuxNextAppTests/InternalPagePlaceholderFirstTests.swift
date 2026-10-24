import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CoreFoundation
import Foundation
import Testing

/// Opening an internal page (Show Ghostty Config Diagnostics opens Settings) builds no page view in the
/// key's turn (sweep m27: commit p95 120 ms, the page built in `openStoreTab`'s turn). The tab and an empty
/// page area show in the key's commit; the provider's view is built right after it, and code that needs
/// it (a route to open) waits through `whenContent`.
@MainActor struct InternalPagePlaceholderFirstTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "placeholder-test")
        var title: String { "Settings" }
        var symbol: String { "gear" }
        var made = 0
        var buildsViewAfterCommit: Bool { true }
        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"placeholder-first-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func openingAPageBuildsItsViewAfterTheKeysCommitNotInIt() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let provider = Provider()
        services.pages.register(provider)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = pane.view
        window.orderFrontRegardless()

        // The key's turn: the tab opens and shows.
        let key = services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(key))
        pane.showSelected()
        let view = try #require(services.pages.existingView(key))
        #expect(view.window === window && !view.isHidden, "the tab's page area did not show in the key's turn")
        #expect(provider.made == 0, "the key's turn built the page view")

        var reached: NSView?
        view.whenContent { reached = $0 }
        #expect(reached == nil)

        // Right after the key's commit: the page view exists, once, in the tab, and its waiter ran.
        await Self.afterCommit()
        #expect(provider.made == 1, "the page view was built \(provider.made) times after the commit")
        let content = try #require(view.content)
        #expect(reached === content)
        #expect(content.superview === view)
    }

    /// Returns after the Core Animation commit that ends this main run-loop turn.
    static func afterCommit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, 2_000_002) { observer, _ in
                CFRunLoopObserverInvalidate(observer)
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }
}
