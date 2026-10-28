import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-28: "WHY WAS THIS NEW TAB BUTTON CHANGED TO BE A DROPDOWN????????????????" Every
/// tab-strip + is a plain one-click action; the chooser remains on hold/right-click. The pane top bar
/// keeps only "⋮", whose menu holds the creation rows.
@MainActor @Suite(.serialized) struct PaneTabBarControlsTests {
    private static func tree(_ surfaces: [UInt64]) -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"tab-bar-controls-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func theTopBarOffersNoCreationButtonsOnlyItsMoreMenu() {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil }, paneTarget: ActionTargetRef(kind: .pane, id: "sample-pane"))
        toolbar.update(target: "sample-terminal", kind: .terminal)
        #expect(toolbar.view.items.isEmpty, "the terminal and browser buttons repeat the + menu, which the ⋮ menu holds")
        #expect(toolbar.view.buttons.isEmpty)
        #expect(toolbar.view.hasMore, "the ⋮ stays for the pane's actions")
    }

    @Test func thePaneStripPlusIsAPlainButtonWithoutATypeMenuOnPress() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: WindowState(record: record))
        defer { pane.teardown() }
        let plus = pane.view.stripView.newTabButton
        #expect(!pane.view.stripView.opensNewTabMenuOnPress, "a press opens the default tab, not the type menu")
        #expect(!plus.showsChevron, "no caret on the pane's +")
        #expect(plus.accessibilityRole() == .button)
    }

    @Test func theScreenBarPlusIsPlainAndHasNoChevron() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1]))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: WindowState(record: record))
        defer { withExtendedLifetime(services) { content.teardown() } }
        let bar = content.screenBar.view
        #expect(!bar.opensNewTabMenuOnPress, "a screen-bar + makes a screen on a plain click")
        #expect(!bar.newTabButton.showsChevron, "the screen-bar + has no dropdown chevron")
        #expect(bar.newTabToolTip == nil, "the + makes a screen, not a tab: no tab tooltip")
    }

    @Test func theSidebarWorkspacePlusIsPlainAndItsNeighborOwnsTheChooser() {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.contextMenuProvider = { _ in NSMenu() }
        #expect(sidebar.newButton.accessibilityRole() == .button, "the + creates a workspace directly")
        #expect(sidebar.newWorkspaceOptionsButton.symbol == "chevron.down", "the chooser is a separate chevron")
        #expect(sidebar.newWorkspaceOptionsButton.pressMenu?() != nil, "the chevron opens workspace options")
        #expect(sidebar.newWorkspaceOptionsButton.frame.height == sidebar.newButton.frame.height,
                "the chevron stays the same height as the +")
    }
}
