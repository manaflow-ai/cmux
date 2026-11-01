import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// Leo 2026-10-28: "WHY WAS THIS NEW TAB BUTTON CHANGED TO BE A DROPDOWN????????????????" Every
/// tab-strip + is a plain one-click action; the chooser remains on hold/right-click. The pane top bar
/// keeps only "⋮", whose menu holds the creation rows.
/// Leo's "+ (v)" adds a separate pane-type chooser beside the pane's + without changing that plain-plus action.
@MainActor @Suite(.closesItsWindows, .serialized) struct PaneTabBarControlsTests {
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

        let strip = pane.view.stripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        defer { window.closeAfterTest() }
        strip.syncFromModel()
        let chooser = try #require(strip.accessibilityChildren()?.compactMap { $0 as? PaneTypeMenuButton }
            .first { $0.accessibilityIdentifier() == "cmux.tabs.newTabMenu" }, "pane types have their own visible chevron")
        #expect(!chooser.isHidden)
        #expect(chooser.accessibilityRole() == .popUpButton)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        strip.layoutSubtreeIfNeeded()
        #expect(chooser.frame.minX >= plus.frame.maxX)
        #expect(chooser.frame.maxX <= strip.bounds.width)
        let chooserPoint = chooser.convert(NSPoint(x: chooser.bounds.midX, y: chooser.bounds.midY), to: strip)
        #expect(strip.titlebarHit(at: chooserPoint) == .strip, "the chooser never drags the window")

        var intents: [TabStripIntent] = []
        strip.model.intentHandler = { intents.append($0) }
        let paneTarget = ActionTargetRef(kind: .pane, id: pane.paneKey)
        var presentations = 0
        var expectsHighlight = true
        strip.presentNewTabMenu = { menu, _, _ in
            presentations += 1
            let actions = menu.items.compactMap { ActionRegistry.menuRun(of: $0) }
            #expect(Array(actions.prefix(3).map(\.id.rawValue)) == ["newSurface", "openBrowser.chromium", "palette.newAgentChat"])
            #expect(actions.prefix(3).allSatisfy { $0.target == paneTarget })
            #expect(chooser.isHighlighted == expectsHighlight, "only the menu's owning chooser stays lit while it tracks")
            #expect(plus.isMenuOpen == !expectsHighlight, "the + stays lit only for its own hold/right-click menu")
        }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                                                  location: strip.convert(chooserPoint, to: nil), modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        #expect(presentations == 1, "mouse-down opens the menu immediately")
        #expect(intents.isEmpty)
        #expect(!strip.pressedNewTab)
        #expect(!chooser.isHighlighted)
        #expect(chooser.accessibilityPerformPress())
        #expect(presentations == 2, "VoiceOver opens the same pane-target menu")
        #expect(chooser.accessibilityPerformShowMenu())
        #expect(presentations == 3, "the accessibility menu action shares that entry point")

        #expect(plus.accessibilityPerformPress())
        #expect(intents == [.newTab(after: nil, sameKind: false)], "the plain + still creates the default tab")
        expectsHighlight = false
        strip.showNewTabMenu()
        #expect(presentations == 4, "the existing hold/right-click entry point keeps the same menu")
    }

    @Test func thePaneChooserStaysBesidePlusDuringMovementAndInterruptedScroll() throws {
        _ = NSApplication.shared
        let tabs = [TabItem(id: TabID("first"), title: "First"), TabItem(id: TabID("last"), title: "Last")]
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: tabs[0].id))
        strip.showsNewTabMenuButton = true
        strip.frame = NSRect(x: 0, y: 0, width: 1000, height: 40)
        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        defer { window.closeAfterTest() }
        strip.layoutSubtreeIfNeeded()
        let plus = try #require(strip.newTabButton.layer)
        let chooser = try #require(strip.newTabMenuButton.layer)
        let spacing = chooser.position.x - plus.position.x
        // Drive the same frame transition a collapsing group produces, then interrupt its scroll.
        // An explicit motion makes sampling deterministic even when the test host disables animations.
        let motion = MotionMove(curve: .tween(.tabMove), duration: 0.2)
        let before = plus.position.x
        let last = try #require(strip.placed[tabs[1].id])
        strip.placed[tabs[1].id] = TabPlace(x: last.x, width: last.width - 60)
        let move = TabStripMove(generation: 100, motion: motion, closing: nil)
        strip.applyFrames(move: move)
        try #require(abs(plus.position.x - before) > 1, "the fixture must move the controls")
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let time = move.begin + motion.duration * fraction
            #expect(abs(MotionPath(chooser, "position").value(at: time).x
                - MotionPath(plus, "position").value(at: time).x - spacing) < 0.5)
        }
        // Finish the layout movement before isolating a scroll and its cancellation.
        TabStripMove.cancel(plus)
        TabStripMove.cancel(chooser)
        let mapping = strip.scrollMapping
        strip.scrollOffset += 20
        let scroll = TabStripMove(generation: 101, motion: motion, closing: nil, isScroll: true)
        strip.applyFrames(move: scroll, scrollFrom: mapping)
        let start = MotionPath(plus, "position").value(at: scroll.begin).x
        let end = MotionPath(plus, "position").value(at: scroll.begin + motion.duration).x
        try #require(abs(start - end) > 1, "the fixture must scroll the controls")
        strip.settleScroll()
        strip.applyFrames()
        let now = CACurrentMediaTime()
        for fraction in [0.0, 0.5, 1.0] {
            let time = now + motion.duration * fraction
            #expect(abs(MotionPath(chooser, "position").value(at: time).x - chooser.position.x) < 0.5,
                    "a wheel interrupt leaves no chooser drift")
            #expect(abs(MotionPath(chooser, "position").value(at: time).x
                - MotionPath(plus, "position").value(at: time).x - spacing) < 0.5)
        }
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
        #expect(bar.accessibilityChildren()?.compactMap { $0 as? PaneTypeMenuButton }
            .contains { $0.accessibilityIdentifier() == "cmux.tabs.newTabMenu" } != true,
            "a screen bar does not gain the pane-type chooser")
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
        // The chevron is opt-in (`sidebar.showNewWorkspaceChooser`, off by default since 2026-10-30).
        let design = DesignSettings()
        design.sidebarSections.showNewWorkspaceChooser = true
        let sidebar = SidebarView(model: SidebarModel(), design: design)
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
        // The chevron is opt-in (`sidebar.showNewWorkspaceChooser`, off by default since 2026-10-30).
        let design = DesignSettings()
        design.sidebarSections.showNewWorkspaceChooser = true
        let sidebar = SidebarView(model: SidebarModel(), design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.newWorkspaceOptionsButton.isHidden, "a roomy sidebar shows the chevron")
        let leftmost = { ([sidebar.newButton, sidebar.newWorkspaceOptionsButton, sidebar.priorityButton] as [NSView])
            .filter { !$0.isHidden }.map(\.frame.minX).min() ?? .infinity }
        let roomy = leftmost()
        // One point less room than the + and its chevron segment need together.
        sidebar.titlebarLeadingReserve = roomy + 1
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.newWorkspaceOptionsButton.isHidden, "the chevron gives way on a narrow sidebar")
        #expect(leftmost() >= sidebar.titlebarLeadingReserve, "no titlebar control enters the reserve")
        sidebar.titlebarLeadingReserve = 0
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.newWorkspaceOptionsButton.isHidden, "the chevron comes back with the room")
    }
}
