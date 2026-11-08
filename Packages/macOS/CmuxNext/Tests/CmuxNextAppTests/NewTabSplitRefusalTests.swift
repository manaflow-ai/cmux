import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// cx-zloqa: Split Right from a page opens the New Tab page in the new pane (here a daemon
/// without `conversation-tab-split-v1`: the page is made hidden, then moved), and keys typed
/// meanwhile wait for its field (cx-kql5h). When the store refuses the page's tab after the
/// split started (the reply fails, or the creation is cancelled), the held keys stayed held
/// until the hold's own limit ran out, four seconds of typing that went nowhere. The refusal
/// ends the hold at once and the keys go on.
@Suite(.closesItsWindows)
@MainActor struct NewTabSplitRefusalTests {
    private struct Refused: Error {}

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"split-refusal-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test(arguments: [false, true])
    func aSplitWhoseTabTheStoreRefusesLetsTheHeldKeysGo(cancelled: Bool) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let tabs = services.agentTabs
        tabs.localHost = "install:split-refusal-test"
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        // The store takes the creation, then refuses it (or the creation is cancelled) after the split started.
        tabs.create = { _, _, _, _, _, _ in
            await Task.yield()
            if cancelled { throw CancellationError() }
            throw Refused()
        }
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.syncStripFromStore()
        // The hold's own limit never ends it during the test: only the refusal can.
        let input = services.keyRouter.newTabInputCoordinator
        input.incomingHoldLimit = .seconds(60)

        NewTabPage.split(pane, edge: .right)
        #expect(input.isHolding(in: window), "the split did not hold the keys typed after it")

        let deadline = ContinuousClock.now + .seconds(2)
        while input.isHolding(in: window), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!input.isHolding(in: window), "the keys stayed held after the store refused the split's tab (cancelled: \(cancelled))")
    }
}
