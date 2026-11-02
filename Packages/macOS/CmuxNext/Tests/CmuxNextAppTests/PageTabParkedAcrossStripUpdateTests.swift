import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// tab-switch-fast review: a Markdown or file viewer tab parked hidden in its pane must stay in the
/// window when the strip updates (a terminal title, a busy dot, a page title). The pane's prune of
/// closed parked content listed only terminals, browsers and agent pages as live, so the next
/// strip update took a parked page out of the window, and switching back paid the WKWebView
/// re-attach again (170-215 ms, #20516). Runs a real `PaneController` in a window.
@Suite(.closesItsWindows)
@MainActor struct PageTabParkedAcrossStripUpdateTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "parking-test")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"page-parking-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func aParkedPageTabStaysInTheWindowWhenTheStripUpdates() throws {
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
        let notes = services.pages.open(provider.page, in: pane.paneKey, of: store)
        let other = services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()

        // Show the notes tab, then switch to the other page tab: notes parks hidden in the pane.
        pane.applySelection(StripTabID(notes))
        pane.showSelected()
        let page = try #require(services.pages.existingView(notes))
        #expect(page.window === window)
        pane.applySelection(StripTabID(other))
        pane.showSelected()
        #expect(page.window === window && page.isHidden, "a switch away parks the page in the window")

        // A strip update (a title, a busy dot): the parked page is still a live tab of this pane.
        pane.syncStripFromStore()
        #expect(page.window === window, "a strip update took the parked page out of the window")

        pane.applySelection(StripTabID(notes))
        pane.showSelected()
        #expect(page.window === window && !page.isHidden)
    }
}
