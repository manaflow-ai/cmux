import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// `window.rail`: the sidebar's sticky sections as an icon rail, where the
/// rail sits for each placement, clearance from the traffic lights, and
/// tooltips with live shortcuts.
@MainActor
@Suite(.serialized)
struct WindowRailTests {
    typealias Coverage = ActionBindingCoverageTests
    private static let frame = NSRect(x: -30_000, y: -30_000, width: 1100, height: 700)

    private func makeWindow(_ services: AppServices, _ placement: WindowRailPlacement) -> WindowController {
        DesignSettings.shared.rail = placement
        let controller = WindowController(state: WindowState(), services: services, frame: Self.frame)
        controller.sidebar.container.restore(width: nil, presentation: .shown)
        controller.window?.layoutIfNeeded()
        controller.root.layoutSubtreeIfNeeded()
        return controller
    }

    private func close(_ controller: WindowController) {
        controller.teardown()
        controller.window?.close()
    }

    /// The rail is a look of the sidebar's layout: it shows the sticky
    /// sections' items (the defaults here) as icons, in band order, with
    /// the top section's rarely used destinations under More, and every
    /// built-in an item can name has the sidebar's action and a real
    /// symbol.
    @Test func theRailShowsTheSidebarsStickySections() {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let controller = makeWindow(services, .leading)
        let column = controller.root.rail.column
        column.layoutSubtreeIfNeeded()
        let ids = { (raw: [String]) in raw.map(LayoutItemID.init) }
        #expect(column.layoutResult.buttons.map(\.item) == ids(["itm_home", "itm_app_store", "itm_history", "itm_notifications", "itm_account"]))
        #expect(Array(column.layoutResult.overflow.prefix(2)) == ids(["itm_settings", "itm_customize"]))
        #expect(column.layoutResult.more != nil)
        for builtIn in SidebarBuiltIn.allCases {
            #expect(SidebarBridge.builtInActions[builtIn] != nil, "\(builtIn) has no action")
            #expect(NSImage(systemSymbolName: builtIn.symbol, accessibilityDescription: nil) != nil, "\(builtIn.symbol)")
        }
        // The new-tab launchers the rail used to hard-code run bound actions.
        for builtIn in [SidebarBuiltIn.newTerminal, .newBrowser, .newAgentChat, .settings, .account] {
            #expect(SidebarBridge.builtInActions[builtIn].map(services.registry.isBound) == true, "\(builtIn) is not bound")
        }
        close(controller)
        withExtendedLifetime(services) {}
    }

    /// Right-clicking a rail item or the empty rail shows the sidebar's
    /// menus, so pinning, removing and reordering work from the rail while
    /// the sidebar hides its bands.
    @Test func railItemsShowTheSidebarsMenus() throws {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let controller = makeWindow(services, .leading)
        let column = controller.root.rail.column
        let home = LayoutItemID("itm_home")
        let menu = try #require(column.contextMenuProvider?(.layoutItem(home)))
        #expect(!menu.items.isEmpty)
        #expect(menu.items.map(\.title) == controller.sidebar.contextMenu(for: .layoutItem(home))?.items.map(\.title))
        #expect(column.contextMenuProvider?(.background) != nil)
        close(controller)
        withExtendedLifetime(services) {}
    }

    /// Waits (bounded) for main-actor observation hops.
    private func eventually(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "line \(line)")
    }

    /// A built-in's tooltip is its action's title and live shortcut, and
    /// follows a rebind on its own (the rail observes the registry's
    /// shortcuts; the test never refreshes it by hand).
    @Test func toolTipsShowTheBoundShortcut() async throws {
        let services = Coverage.boundServices()
        let registry = services.registry
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let browserShortcut = try #require(registry.shortcutDisplay(for: "openBrowser"))
        #expect(WindowRail.toolTip(for: .builtIn(.newBrowser), registry: registry) == "New Browser Tab (\(browserShortcut))")
        // No shortcut: the title alone, without the menu ellipsis.
        #expect(WindowRail.toolTip(for: .builtIn(.account), registry: registry) == "Accounts")
        // Not a built-in: the item's own title.
        #expect(WindowRail.toolTip(for: .url("https://example.com"), registry: registry) == nil)

        let controller = makeWindow(services, .leading)
        let column = controller.root.rail.column
        column.layoutSubtreeIfNeeded()
        let history = LayoutItemID("itm_history")
        registry.setShortcutOverride(Shortcut("s", modifiers: [.control, .option, .command]), for: "history.show")
        try await eventually {
            column.layoutSubtreeIfNeeded()
            return column.itemView(history)?.toolTip == "\(WindowRail.title(for: "history.show", registry: registry)) (⌃⌥⌘S)"
        }
        registry.setShortcutOverride(nil, for: "history.show")
        close(controller)
        withExtendedLifetime(services) {}
    }

    /// "off" is the layout without a rail; "leading" puts it before the
    /// sidebar; "afterSidebar" between the sidebar and the content column.
    @Test func placementPutsTheRailInTheWindowsColumnChain() {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        for placement in WindowRailPlacement.allCases {
            let controller = makeWindow(services, placement)
            let root = controller.root
            let rail = root.rail.frame
            let sidebar = controller.sidebar.container.frame
            let content = root.contentHost.frame
            #expect(sidebar.width > 0, "\(placement): sidebar hidden")
            #expect(content.maxX == root.bounds.maxX, "\(placement)")
            switch placement {
            case .off:
                #expect(root.rail.superview == nil)
                #expect(sidebar.minX == 0)
                #expect(content.minX == sidebar.maxX)
            case .leading:
                #expect(root.rail.superview === root)
                #expect(rail.minX == 0 && rail.width == WindowRail.width)
                #expect(sidebar.minX == rail.maxX)
                #expect(content.minX == sidebar.maxX)
            case .afterSidebar:
                #expect(root.rail.superview === root)
                #expect(sidebar.minX == 0)
                #expect(rail.minX == sidebar.maxX && rail.width == WindowRail.width)
                #expect(content.minX == rail.maxX)
            }
            if placement != .off {
                #expect(rail.minY == root.bounds.minY && rail.maxY == root.bounds.maxY, "\(placement): rail not full height")
                // The band below the workspace list is pinned to the bottom,
                // under the band above it.
                let column = root.rail.column
                column.layoutSubtreeIfNeeded()
                let bands = SidebarLayoutDocument.defaults.bands(room: nil)
                let below = Set(bands.below.flatMap(\.items).map(\.id))
                let buttons = column.layoutResult.buttons
                let top = buttons.filter { !below.contains($0.item) }.map(\.frame)
                let bottom = buttons.filter { below.contains($0.item) }.map(\.frame)
                #expect(!top.isEmpty && !bottom.isEmpty, "\(placement)")
                #expect(bottom.map(\.minY).min()! > top.map(\.maxY).max()!, "\(placement): bottom band not below the top band")
                #expect(column.bounds.height - bottom.map(\.maxY).max()! < 40, "\(placement): bottom band not pinned to the bottom")
            }
            close(controller)
        }
        withExtendedLifetime(services) {}
    }

    /// A cmux.json change re-lays out an open window on its own (the root
    /// observes the setting; the test never applies it by hand).
    @Test func changingThePlacementRelaysOutAnOpenWindow() async throws {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let controller = makeWindow(services, .off)
        let root = controller.root
        let before = root.contentHost.frame
        DesignSettings.shared.rail = .afterSidebar
        try await eventually { root.rail.superview === root }
        root.layoutSubtreeIfNeeded()
        #expect(root.contentHost.frame.minX == before.minX + WindowRail.width)
        DesignSettings.shared.rail = .off
        try await eventually { root.rail.superview == nil }
        root.layoutSubtreeIfNeeded()
        #expect(root.contentHost.frame == before)
        close(controller)
        withExtendedLifetime(services) {}
    }

    /// At the window's leading edge, or after a hidden sidebar, the rail is
    /// under the traffic lights: its buttons start below them in both
    /// titlebar styles, even with a top row shorter than the lights (a
    /// tuned titlebar height), so the lights check itself is what holds.
    @Test func railButtonsClearTheTrafficLights() throws {
        let services = Coverage.boundServices()
        let savedRail = DesignSettings.shared.rail
        let savedTitlebar = DesignSettings.shared.titlebar
        defer {
            DesignSettings.shared.rail = savedRail
            DesignSettings.shared.titlebar = savedTitlebar
        }
        for style in TitlebarStyle.allCases {
            for placement in [WindowRailPlacement.leading, .afterSidebar] {
                DesignSettings.shared.titlebar = style
                let controller = makeWindow(services, placement)
                if placement == .afterSidebar {
                    controller.sidebar.container.restore(width: nil, presentation: .hidden)
                    controller.root.layoutSubtreeIfNeeded()
                    #expect(controller.root.rail.frame.minX == 0, "\(style): rail not at the leading edge")
                }
                let window = try #require(controller.window)
                let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
                for inset in [controller.root.rail.topInset, 0] {
                    controller.root.rail.topInset = inset
                    controller.root.layoutSubtreeIfNeeded()
                    let column = controller.root.rail.column
                    column.layoutSubtreeIfNeeded()
                    for button in column.layoutResult.buttons {
                        let view = try #require(column.itemView(button.item))
                        let frame = view.convert(view.bounds, to: nil)
                        #expect(frame.maxY <= lights.minY,
                                "\(style) \(placement) inset \(inset): \(button.item) at \(frame) overlaps the lights at \(lights)")
                    }
                }
                close(controller)
            }
        }
        withExtendedLifetime(services) {}
    }

    /// With the rail at the window's leading edge (the default, the Codex
    /// app's skinny strip) the sidebar is an inset panel beside it: it
    /// starts below the top row, reaches the bottom, rounds only its top
    /// leading corner, and fills with the theme's sidebar step over the
    /// window backdrop, so the rail reads one tone darker (lighter themes:
    /// one tone lighter). The other placements keep one sheet.
    @Test func theLeadingRailSitsBesideAnInsetSidebarPanel() throws {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        for placement in WindowRailPlacement.allCases {
            let controller = makeWindow(services, placement)
            let root = controller.root
            let panel = root.sidebarPanel
            if placement == .leading {
                #expect(panel.superview === root)
                #expect(root.subviews.first === root.backdropView, "the panel sits on the backdrop")
                let sidebar = controller.sidebar.container.frame
                #expect(panel.frame.minX == sidebar.minX && panel.frame.width == sidebar.width)
                #expect(panel.frame.minX == root.rail.frame.maxX)
                #expect(panel.frame.minY == root.bounds.minY)
                #expect(panel.frame.maxY == root.bounds.maxY - root.rail.topInset, "starts below the top row")
                let layer = try #require(panel.layer)
                #expect(layer.cornerRadius == Metrics.panelCornerRadius)
                #expect(layer.maskedCorners == [.layerMinXMaxYCorner])
                let fill = try #require(layer.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
                let step = try #require(root.performWithTheme { Palette.sidebarStep }.usingColorSpace(.sRGB))
                #expect(abs(fill.redComponent - step.redComponent) < 0.004 && abs(fill.greenComponent - step.greenComponent) < 0.004
                    && abs(fill.blueComponent - step.blueComponent) < 0.004 && abs(fill.alphaComponent - step.alphaComponent) < 0.004,
                        "\(fill) is not the sidebar step \(step)")
            } else {
                #expect(panel.superview == nil, "\(placement)")
            }
            close(controller)
        }
        withExtendedLifetime(services) {}
    }

    /// A hidden sidebar takes its panel with it: the rail and the content
    /// column meet on the one backdrop.
    @Test func theInsetPanelFollowsTheSidebarsWidth() {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let controller = makeWindow(services, .leading)
        controller.sidebar.container.restore(width: nil, presentation: .hidden)
        controller.root.layoutSubtreeIfNeeded()
        #expect(controller.root.sidebarPanel.frame.width == 0)
        #expect(controller.root.contentHost.frame.minX == WindowRail.width)
        close(controller)
        withExtendedLifetime(services) {}
    }
}
