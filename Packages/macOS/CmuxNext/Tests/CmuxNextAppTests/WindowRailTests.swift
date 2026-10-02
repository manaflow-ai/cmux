import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// `window.rail`: the icon rail's buttons and their actions, where the rail
/// sits for each placement, clearance from the traffic lights, and tooltips
/// with live shortcuts.
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

    @Test func buttonsRunTheirRegistryActionsInOrder() {
        let services = Coverage.boundServices()
        let rail = WindowRailView(registry: services.registry)
        #expect(rail.buttons.map(\.item.action) == [
            "newSurface", "openBrowser", "palette.newAgentChat", "showNotifications", "history.show", "accounts.show",
        ])
        #expect(rail.buttons.last?.item == WindowRail.account)
        for button in rail.buttons {
            #expect(services.registry.isBound(button.item.action), "\(button.item.action) is not bound")
            #expect(NSImage(systemSymbolName: button.item.symbol, accessibilityDescription: nil) != nil, "\(button.item.symbol)")
            #expect(button.accessibilityLabel() == WindowRail.title(for: button.item.action, registry: services.registry))
        }
        withExtendedLifetime(services) {}
    }

    @Test func toolTipsShowTheBoundShortcut() throws {
        let services = Coverage.boundServices()
        let registry = services.registry
        let rail = WindowRailView(registry: registry)
        func tip(_ id: ActionID) -> String? { rail.buttons.first { $0.item.action == id }?.toolTip }

        let browserShortcut = try #require(registry.shortcutDisplay(for: "openBrowser"))
        #expect(tip("openBrowser") == "New Browser Tab (\(browserShortcut))")
        let inboxShortcut = try #require(registry.shortcutDisplay(for: "showNotifications"))
        #expect(tip("showNotifications") == "Show Notifications (\(inboxShortcut))")
        // No shortcut: the title alone, without the menu ellipsis.
        #expect(tip("accounts.show") == "Accounts")

        registry.setShortcutOverride(Shortcut("t", modifiers: [.control, .option, .command]), for: "newSurface")
        rail.refreshToolTips()
        #expect(tip("newSurface") == "New Terminal Tab (⌃⌥⌘T)")
        registry.setShortcutOverride(nil, for: "openBrowser")
        rail.refreshToolTips()
        #expect(tip("openBrowser") == "New Browser Tab")
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
                // Accounts sits at the bottom, below the top group.
                let buttons = root.rail.buttons
                let top = buttons.filter { $0.item != WindowRail.account }.map(\.frame)
                let account = buttons.first { $0.item == WindowRail.account }!.frame
                #expect(top.map(\.minY) == top.map(\.minY).sorted(), "\(placement): top group out of order")
                #expect(account.minY > top.map(\.maxY).max()!, "\(placement): accounts not pinned to the bottom")
            }
            close(controller)
        }
        withExtendedLifetime(services) {}
    }

    /// A cmux.json change re-lays out an open window.
    @Test func changingThePlacementRelaysOutAnOpenWindow() {
        let services = Coverage.boundServices()
        let saved = DesignSettings.shared.rail
        defer { DesignSettings.shared.rail = saved }
        let controller = makeWindow(services, .off)
        let root = controller.root
        let before = root.contentHost.frame
        DesignSettings.shared.rail = .afterSidebar
        root.applyRail()
        root.layoutSubtreeIfNeeded()
        #expect(root.contentHost.frame.minX == before.minX + WindowRail.width)
        DesignSettings.shared.rail = .off
        root.applyRail()
        root.layoutSubtreeIfNeeded()
        #expect(root.rail.superview == nil)
        #expect(root.contentHost.frame == before)
        close(controller)
        withExtendedLifetime(services) {}
    }

    /// At the window's leading edge the rail is under the traffic lights:
    /// its buttons start below them in both titlebar styles.
    @Test func leadingRailButtonsClearTheTrafficLights() throws {
        let services = Coverage.boundServices()
        let savedRail = DesignSettings.shared.rail
        let savedTitlebar = DesignSettings.shared.titlebar
        defer {
            DesignSettings.shared.rail = savedRail
            DesignSettings.shared.titlebar = savedTitlebar
        }
        for style in TitlebarStyle.allCases {
            DesignSettings.shared.titlebar = style
            let controller = makeWindow(services, .leading)
            let window = try #require(controller.window)
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            for button in controller.root.rail.buttons {
                let frame = button.convert(button.bounds, to: nil)
                #expect(frame.maxY <= lights.minY, "\(style): \(button.item.action) at \(frame) overlaps the lights at \(lights)")
            }
            close(controller)
        }
        withExtendedLifetime(services) {}
    }
}
