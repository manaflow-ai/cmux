import AppKit
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextFocus
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// TERMINAL CREATE COST (STATUS 13444): under STRESS (14 panes of 6 tabs) New Terminal Tab and New Column spend 9 ms of
/// main-thread work after the key's handler and before the turn's Core Animation commit, 72 % of it Swift Observation
/// re-tracking. The largest single caller is each pane's strip items (`PaneController.tabItems`): about one re-track per
/// tab of the session for one new tab, so the work is O(session), not O(changed). A new tab in one pane must re-run no
/// strip item of another pane's tabs.
///
/// Each read `PaneController.tabItem(_:)` makes is tracked on its own too, so a failure names the read that the new tab
/// wakes. The daemon is an offline store; the new tab is the key's intent (`NewTerminalTabCommand.intendNow`).
@Suite(.closesItsWindows)
@MainActor struct NewTabStripItemFanOutTests {
    private static func tree() -> DaemonTree {
        let left = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [1, 2].map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let right = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [3, 4].map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: 1, layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)),
                                    panes: [left, right])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"new-tab-fan-out-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// The names whose tracked read a change woke (the change's `willSet` runs on the main thread here).
    private final class Woken: @unchecked Sendable {
        var names: [String] = []
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewTabInOnePaneReRunsNoStripItemOfAnotherPane() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let panes = try #require(workspace.screens.first?.panes)
        let left = try #require(panes.first { $0.handle == PaneID(rawValue: 1) })
        let right = try #require(panes.first { $0.handle == PaneID(rawValue: 2) })
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let leftPane = PaneController(pane: left, daemon: services.daemon, layoutPaneID: LayoutPaneID(left.id), services: services, state: state)
        let rightPane = PaneController(pane: right, daemon: services.daemon, layoutPaneID: LayoutPaneID(right.id), services: services, state: state)
        defer { withExtendedLifetime((services, state)) { leftPane.teardown(); rightPane.teardown() } }
        leftPane.syncStripFromStore()
        rightPane.syncStripFromStore()
        await Self.drainMain()
        let tab = try #require(right.tabs.first, "fixture: the right pane has tabs")

        let woken = Woken()
        func track(_ name: String, _ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { woken.names.append(name) }
        }
        let machine = services.daemon.machineID
        // The whole strip item, then each read it makes (PaneController.tabItem).
        track("tabItem") { _ = rightPane.tabItem(tab) }
        track("tab's own fields") { _ = (tab.title, tab.kind, tab.agentSession, tab.tabGroup, tab.page, tab.appTab, tab.url) }
        track("focus kind") { _ = FocusTopology.Kind.of(tab) }
        track("workspace(containing:)") { _ = store.workspace(containing: right.handle) }
        track("workspace handle") { _ = workspace.handle }
        track("titles") {
            let titles = TabTitleResolver(services: services, workspace: workspace.handle)
            _ = titles.isNewTabPage(tab)
            _ = titles.untitled(tab, fallback: "~")
            _ = titles.page(tab)
        }
        track("restartsKeptTab") { _ = services.daemon.restartsKeptTab(tab) }
        track("item mapping") {
            var item = TabItemMapping.shared.item(tab, fallbackTitle: "~", isNewTabPage: false, restarting: false,
                                                  harnessIcons: services.harnessIconLookup)
            TabItemMapping.shared.applyUserIcon(tab, to: &item, asset: IconAssetImages.shared.tabIcon(owner: services.daemon))
        }
        track("home unread") { _ = services.home.unreadConversations.isEmpty }
        track("attention setting") { _ = DesignSettings.shared.attention.showsOnTab }
        track("dormant") { _ = services.cache.dormantTabs.contains(tab.id) }
        track("machines") { _ = services.machines.tabBadge(machine) }
        track("themes") { _ = services.themes.badge(forTerminal: TerminalThemeKey(machine: machine, tab: tab)) }

        // The key's turn of New Terminal Tab in the left pane: the stand-in tab in the store, applied to its strip.
        let provisional = ProvisionalTab()
        store.intend(.createTab(pane: left.handle, provisional: provisional.terminal(TerminalID.generate(), cwd: nil)),
                     transaction: ClientTransactionID.generate())
        leftPane.syncStripFromStore()
        await Self.drainMain()

        #expect(left.tabs.contains { $0.surface == provisional.surface }, "fixture: the new tab is not in the left pane")
        #expect(woken.names.isEmpty, "a new tab in another pane woke these reads of the right pane's strip item: \(woken.names)")
    }
}
