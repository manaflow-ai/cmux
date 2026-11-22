import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A parked workspace (mounted off screen by its window, `WorkspaceContentController.park`) draws
/// nothing, so its panes do no work for it (PL-script A2): selections and column changes while it
/// is parked only mark the pane dirty. They make no page or surface and map no strip. Unparking
/// shows the last state once: one strip map, one page for the selected tab.
@Suite(.closesItsWindows)
@MainActor struct ParkedWorkspacePaneWorkTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "parked-work-test")
        private(set) var made = 0
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }
    }

    private static func tree(widths: (Double, Double)) -> DaemonTree {
        let first = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "~")])
        let second = PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, title: "~")])
        let columns = [ColumnSnapshot(id: 10, width: widths.0, layout: .leaf(1)), ColumnSnapshot(id: 11, width: widths.1, layout: .leaf(2))]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: [first, second])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"parked-work-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the main actor run what is queued (observation steps): a fixed number of yields, no wait
    /// for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aParkedWorkspacesPanesDoNoWorkUntilItIsShownAgain() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(widths: (0.5, 0.5)))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let provider = Provider()
        services.pages.register(provider)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let pane = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
        // Five page tabs; the first is shown. A page is made the first time its tab shows.
        let pages = (0..<5).map { _ in services.pages.open(provider.page, in: pane.paneKey, of: store) }
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(pages[0]))
        pane.showSelected() // the display frame the presentation scheduler queued it for (no frames run in a test)
        await Self.drainMain()
        #expect(pane.currentTabKey == pages[0])

        content.park(serial: 1)
        let made = provider.made, maps = pane.debugSnapshotRuns
        for round in 0..<50 {
            pane.applySelection(StripTabID(pages[1 + round % 4])) // the last round selects pages[2]
            pane.showSelected() // the frame the scheduler would run for it
            let left = 0.3 + Double(round % 5) * 0.05
            store.apply(snapshot: Self.tree(widths: (left, 1 - left)))
        }
        await Self.drainMain()

        #expect(provider.made - made == 0, "50 selections while parked made \(provider.made - made) pages")
        #expect(pane.debugSnapshotRuns - maps == 0,
                "50 selections and column changes while parked mapped the strip \(pane.debugSnapshotRuns - maps) times")

        let madeBefore = provider.made, mapsBefore = pane.debugSnapshotRuns
        content.unpark()
        await Self.drainMain()
        pane.showSelected() // the frame after unpark

        #expect(provider.made - madeBefore == 1, "unpark shows the last selection once: made \(provider.made - madeBefore) pages")
        #expect(pane.debugSnapshotRuns - mapsBefore == 1, "unpark maps the strip once: \(pane.debugSnapshotRuns - mapsBefore) times")
        #expect(pane.currentTabKey == pages[2], "the shown tab is the last one selected while parked")
    }
}
