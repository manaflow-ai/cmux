import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Dogfood nxdog12: "traffic light buttons disappeared". The close,
/// minimize and zoom buttons must show in every window: minimal and
/// standard titlebar, normal and incognito, config and room themes, opaque
/// and translucent backgrounds.
@MainActor
@Suite(.serialized)
struct WindowTrafficLightsTests {
    private static let frame = NSRect(x: -30_000, y: -30_000, width: 900, height: 600)

    private static let roomTheme = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328))
    private static let translucentTheme = ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4),
                                                     backgroundOpacity: 0.85)

    /// Checks the three standard buttons of `controller`'s window: present,
    /// shown, opaque, inside the window frame, and in a titlebar that
    /// draws above the window's content view.
    private func expectTrafficLights(_ controller: WindowController, _ label: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        guard let window = controller.window, let content = window.contentView, let frameView = content.superview else {
            Issue.record("\(label): no window", sourceLocation: sourceLocation)
            return
        }
        window.layoutIfNeeded()
        let bounds = frameView.bounds
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else {
                Issue.record("\(label): no \(type) button", sourceLocation: sourceLocation)
                continue
            }
            #expect(!button.isHiddenOrHasHiddenAncestor, "\(label): \(type) hidden", sourceLocation: sourceLocation)
            #expect(button.alphaValue == 1, "\(label): \(type) alpha \(button.alphaValue)", sourceLocation: sourceLocation)
            let rect = button.convert(button.bounds, to: frameView)
            #expect(rect.width > 0 && bounds.contains(rect), "\(label): \(type) at \(rect) outside \(bounds)",
                    sourceLocation: sourceLocation)
            // The theme-frame subview holding the button must be above the
            // content view, or the content's opaque background covers it.
            var holder: NSView = button
            while let parent = holder.superview, parent !== frameView { holder = parent }
            let order = frameView.subviews
            let holderIndex = order.firstIndex { $0 === holder } ?? -1
            let contentIndex = order.firstIndex { $0 === content } ?? Int.max
            #expect(holderIndex > contentIndex,
                    "\(label): \(type) is under the content view (\(order.map { String(describing: Swift.type(of: $0)) }))",
                    sourceLocation: sourceLocation)
        }
    }

    private func makeWindow(_ services: AppServices) -> WindowController {
        WindowController(state: WindowState(), services: services, frame: Self.frame)
    }

    @Test func minimalAndStandardWindowsShowTheTrafficLights() {
        let services = ActionBindingCoverageTests.boundServices()
        let saved = DesignSettings.shared.titlebar
        defer { DesignSettings.shared.titlebar = saved }
        for style in TitlebarStyle.allCases {
            DesignSettings.shared.titlebar = style
            let controller = makeWindow(services)
            expectTrafficLights(controller, "\(style)")
            controller.teardown()
            controller.window?.close()
        }
        withExtendedLifetime(services) {}
    }

    @Test func incognitoWindowsShowTheTrafficLightsWithAndWithoutTheSidebar() {
        let services = ActionBindingCoverageTests.boundServices()
        let controller = makeWindow(services)
        controller.showIncognitoBadge()
        expectTrafficLights(controller, "incognito")
        controller.root.showsTitlebarBadge = true
        controller.root.layoutSubtreeIfNeeded()
        expectTrafficLights(controller, "incognito, sidebar hidden")
        controller.teardown()
        controller.window?.close()
        withExtendedLifetime(services) {}
    }

    /// Lawrence (nxdog41): with the sidebar hidden, the window's controls (traffic lights and the
    /// titlebar band) collapse at rest so the top-left strip's tabs start at the left edge, and come
    /// back while the pointer is over the top-left corner or the band has keyboard focus. With the
    /// sidebar shown they never collapse.
    @Test func hiddenSidebarCollapsesTheWindowControlsUntilTheCornerIsHovered() {
        let services = ActionBindingCoverageTests.boundServices()
        let controller = makeWindow(services)
        let root = controller.root
        root.layoutSubtreeIfNeeded()
        #expect(!root.windowControlsCollapsed, "sidebar shown: never collapsed")
        root.sidebarHidden = true
        #expect(root.windowControlsCollapsed, "sidebar hidden, pointer elsewhere: collapsed")
        #expect((controller.window as? TitlebarAccessoryHosting)?.windowControlsCollapsed == true)
        // The corner region covers the traffic lights, so a move straight to Close reveals first.
        if let window = controller.window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            let corner = root.cornerRegionFrameInWindow
            #expect(corner.contains(lights), "corner \(corner) covers the traffic lights \(lights)")
        }
        root.cornerReveal.setPointerInside(true)
        #expect(!root.windowControlsCollapsed, "pointer on the top-left corner: shown")
        root.cornerReveal.setPointerInside(false)
        #expect(root.windowControlsCollapsed)
        root.sidebarHidden = false
        #expect(!root.windowControlsCollapsed)
        controller.teardown()
        controller.window?.close()
        withExtendedLifetime(services) {}
    }

    /// nxdog43: a hover that leaves the corner re-collapses the controls (the pointer's exit reaches
    /// the corner region's tracking area). Driven through DebugHover, the same events a real pointer
    /// crossing causes.
    @Test func leavingTheCornerCollapsesTheControlsAgain() {
        let services = ActionBindingCoverageTests.boundServices()
        let controller = makeWindow(services)
        let root = controller.root
        guard let window = controller.window else {
            Issue.record("no window")
            return
        }
        root.layoutSubtreeIfNeeded()
        root.sidebarHidden = true
        root.layoutSubtreeIfNeeded()
        let corner = root.cornerRegionFrameInWindow
        #expect(corner.width > 0, "corner \(corner)")
        _ = DebugHover.move(to: NSPoint(x: corner.minX + 10, y: corner.midY), in: window)
        #expect(!root.windowControlsCollapsed, "hovering the corner shows the controls")
        _ = DebugHover.move(to: NSPoint(x: corner.maxX + 300, y: corner.minY - 200), in: window)
        #expect(root.cornerReveal.state.pointerInside == false, "the exit reached the corner region")
        #expect(root.windowControlsCollapsed, "leaving the corner collapses them again")
        controller.teardown()
        controller.window?.close()
        withExtendedLifetime(services) {}
    }

    @Test func themedAndTranslucentWindowsShowTheTrafficLights() {
        let services = ActionBindingCoverageTests.boundServices()
        let controller = makeWindow(services)
        controller.themeScope.setOverride(ThemeSpec("GitHub Light Default"), input: Self.roomTheme, animated: false)
        controller.root.themeDidChange()
        expectTrafficLights(controller, "room theme")
        controller.themeScope.setOverride(ThemeSpec("Catppuccin Mocha"), input: Self.translucentTheme, animated: false)
        controller.root.themeDidChange()
        expectTrafficLights(controller, "translucent room theme")
        controller.teardown()
        controller.window?.close()
        withExtendedLifetime(services) {}
    }
}
