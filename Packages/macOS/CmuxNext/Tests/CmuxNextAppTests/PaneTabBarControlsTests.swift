import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import QuartzCore
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

    @Test func pressingThePlainPlusChangesItsGlyphEvenWhenHovered() throws {
        let plus = NewTabButtonView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        plus.isHovered = true
        let glyph = try #require(plus.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let hoverWidth = glyph.lineWidth
        plus.isPressed = true
        #expect(glyph.lineWidth > hoverWidth, "a press is visible even after hover brightens the glyph")
        #expect(plus.layer?.sublayers?.first?.backgroundColor == nil, "a press adds no plate")
        plus.isPressed = false
        #expect(glyph.lineWidth == hoverWidth, "release restores the hover glyph")
    }

    @Test func theSidebarWorkspacePlusIsPlainAndItsNeighborOwnsTheChooser() {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        sidebar.contextMenuProvider = { _ in menu }
        // The + is a plain action: a press runs it and opens no menu. (An off-window SidebarIconButton
        // reports AXUnknown for its role on the CI minis, so the press itself is what is checked.)
        var plusPresses = 0
        let plusAction = sidebar.newButton.onPress
        sidebar.newButton.onPress = { plusPresses += 1 }
        #expect(sidebar.newButton.accessibilityPerformPress(), "the + creates a workspace directly")
        #expect(plusPresses == 1)
        sidebar.newButton.onPress = plusAction
        #expect(sidebar.newWorkspaceOptionsButton.symbol == "chevron.down", "the chooser is a separate chevron")
        #expect(sidebar.newWorkspaceOptionsButton.pressMenu?() != nil, "the chevron opens workspace options")
        #expect(sidebar.newWorkspaceOptionsButton.alphaValue == sidebar.newButton.alphaValue,
                "the + and its chevron start revealed together")
        #expect(sidebar.newWorkspaceOptionsButton.frame.height == sidebar.newButton.frame.height,
                "the chevron stays the same height as the +")
        var presentations = 0
        sidebar.newWorkspaceOptionsButton.presentMenu = { _, _ in presentations += 1 }
        #expect(sidebar.newWorkspaceOptionsButton.accessibilityPerformPress(),
                "VoiceOver can open the workspace chooser")
        #expect(presentations == 1)
        sidebar.newWorkspaceOptionsButton.performClick(nil)
        #expect(presentations == 2, "Space/keyboard activation opens the same chooser")
    }
    /// Leo 2026-10-26: "If it's a toggle, if it's something like that, then you keep it on when you click the
    /// context menu, when you click the top, the drop-down, the popover, whatever the fuck. We say we keep it."
    /// With controls on hover, the + and its chevron stay revealed and lit while the menu either one opened
    /// is open, though the pointer leaves the sidebar for the menu; the reveal follows the pointer again on close.
    @Test func theSidebarPlusAndChevronStayRevealedWhileTheirMenuIsOpen() throws {
        _ = NSApplication.shared
        let design = DesignSettings()
        design.sidebarSections.controlsOnHover = true
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        sidebar.contextMenuProvider = { _ in menu }
        let shown = sidebar.chromeReveal(revealed: true).newButton
        let hidden = sidebar.chromeReveal(revealed: false).newButton
        #expect(hidden < shown, "controls on hover hides the + with the pointer away")

        // The chevron's press menu: the pointer arrives, presses, then leaves for the menu.
        sidebar.setChromeRevealed(true)
        var whileOpen: (revealed: Bool, target: CGFloat?, lit: Bool)?
        sidebar.newWorkspaceOptionsButton.presentMenu = { _, button in
            sidebar.setChromeRevealed(false) // the pointer hover clears as the pointer moves into the menu
            whileOpen = (sidebar.isChromeRevealed, sidebar.appliedChromeReveal?.newButton, button.hover.state.pressed)
        }
        sidebar.newWorkspaceOptionsButton.performPressMenu()
        let open = try #require(whileOpen)
        #expect(open.revealed && open.target == shown, "the + and chevron stay revealed while the chooser is open")
        #expect(open.lit, "the chevron stays lit while its menu is open")
        #expect(!sidebar.isChromeRevealed && sidebar.appliedChromeReveal?.newButton == hidden,
                "on close the reveal follows the pointer, which has left")
        #expect(!sidebar.newWorkspaceOptionsButton.hover.state.pressed)

        // The +'s own right-click menu holds the reveal the same way.
        sidebar.setChromeRevealed(true)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        sidebar.newButton.willOpenMenu(menu, with: event)
        sidebar.setChromeRevealed(false)
        #expect(sidebar.isChromeRevealed && sidebar.appliedChromeReveal?.newButton == shown)
        #expect(sidebar.newButton.hover.state.pressed, "the + stays lit while its menu is open")
        sidebar.newButton.didCloseMenu(menu, with: nil)
        #expect(!sidebar.isChromeRevealed && sidebar.appliedChromeReveal?.newButton == hidden)
        #expect(!sidebar.newButton.hover.state.pressed)
    }
    /// A narrow sidebar never puts the chevron (or, pushed by it, the Priority button) into the titlebar's leading
    /// reserve, where the toolbar band above the sidebar takes the clicks: the chevron hides first, and the +'s
    /// right-click menu still opens the chooser.
    @Test func theSidebarChevronHidesBeforeItReachesTheLeadingReserve() {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.newWorkspaceOptionsButton.isHidden, "a roomy sidebar shows the chevron")
        let leftmost = { ([sidebar.newButton, sidebar.newWorkspaceOptionsButton, sidebar.priorityButton] as [NSView])
            .filter { !$0.isHidden }.map(\.frame.minX).min() ?? .infinity }
        let roomy = leftmost()
        // Room for exactly what sat beside the + before the chevron existed, and not one point more.
        sidebar.titlebarLeadingReserve = roomy + Metrics.space1 + SidebarStyle.toolbarButtonSize
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.newWorkspaceOptionsButton.isHidden, "the chevron gives way on a narrow sidebar")
        #expect(leftmost() >= sidebar.titlebarLeadingReserve, "no titlebar control enters the reserve")
        sidebar.titlebarLeadingReserve = 0
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.newWorkspaceOptionsButton.isHidden, "the chevron comes back with the room")
    }
}
