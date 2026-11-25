import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo, 2026-11-03: "when i create a new tab here with cmd t it makes it... then removes it after a second".
/// A workspace that draws nothing (parked) maps no strip, so a tab the store adds to its pane never shows
/// while it stays that way. When the person acts on one of its panes (Cmd-T, a new tab, a select) and its
/// view is in the window and not hidden, it draws again: the strip lists the store's tabs at once. A
/// workspace whose view is hidden stays parked.
@Suite(.closesItsWindows)
@MainActor struct WorkspaceDrawsOnScreenTests {
    private static func tree(tabs: Int) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "~") })
        let columns = [ColumnSnapshot(id: 10, width: 1, layout: .leaf(1))]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"draws-on-screen-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aParkedWorkspaceTheWindowShowsListsTheStoresNewTabOnThePersonsAction(hidden: Bool) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree(tabs: 1))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { withExtendedLifetime(services) { content.teardown(); window.close() } }
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let pane = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
        await Self.drainMain()
        #expect(pane.stripModel.orderedTabs.count == 1)

        // Parked, yet (unless `hidden`) still in the window: the store's new tab maps into no strip.
        content.park(serial: 1)
        content.contentView.isHidden = hidden
        store.apply(snapshot: Self.tree(tabs: 2))
        await Self.drainMain()
        #expect(pane.pane.tabs.count == 2)
        #expect(pane.stripModel.orderedTabs.count == 1, "a parked workspace mapped its strip")

        // The person's new tab in that pane (Cmd-T) finds the workspace on screen or not.
        pane.drawIfOnScreen("test")
        await Self.drainMain()
        if hidden {
            #expect(content.drawsNothing, "a hidden workspace was drawn")
            #expect(pane.isSuspended)
        } else {
            #expect(!content.drawsNothing, "the workspace the window shows still draws nothing")
            #expect(!pane.isSuspended)
            #expect(pane.stripModel.orderedTabs.count == 2, "the store's new tab stayed out of the strip (it showed, then left)")
        }
    }
}
