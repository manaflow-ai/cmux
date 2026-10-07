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

    /// Leo (T3 Code ref, 2026-10-07), replacing nxdog41's corner collapse: with the sidebar hidden
    /// the traffic lights and the band (the sidebar toggle first) stay shown at rest, with no hover,
    /// so the toggle is one fixed target open or collapsed.
    @Test func hiddenSidebarKeepsTheWindowControlsShown() {
        let services = ActionBindingCoverageTests.boundServices()
        let controller = makeWindow(services)
        let root = controller.root
        root.layoutSubtreeIfNeeded()
        root.sidebarHidden = true
        root.layoutSubtreeIfNeeded()
        #expect(!root.trafficLightButtons.isEmpty)
        for button in root.trafficLightButtons { #expect(button.alphaValue == 1, "traffic light shown at rest") }
        #expect(root.toolbarBand.alphaValue == 1, "the band shows at rest")
        #expect(root.toolbarBand.sidebarToggle.alphaValue == 1, "the toggle shows at rest")
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
