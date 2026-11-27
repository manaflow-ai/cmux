import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSidebar
import Testing

/// Austin 2026-11-10: "We need to make sure that the traffic lights are aligned to the densities as well
/// (will need to adjust them as well according to which density the user selects)". In a real window the
/// lights center on the top row's line, the line the toolbar band and the tab pills share, at every density;
/// with the `lights` line (the row follows the lights) they stay where macOS puts them.
@MainActor @Suite(.serialized) struct TrafficLightsDensityTests {
    private func window() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        settle(root)
        return (window, root)
    }

    private func settle(_ root: WindowRootView) {
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    /// The lights' center below the window's top edge.
    private func lightsCenter(_ window: NSWindow) throws -> CGFloat {
        let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        return window.frame.height - lights.midY
    }

    @Test(arguments: DensityPreset.allCases)
    func theLightsCenterOnTheTopRowLine(density: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let (window, root) = window()
        defer { window.close() }
        let line = try #require(WindowTitlebar.topRowLine(in: window), "\(density): no top row line")
        let center = try lightsCenter(window)
        let band = root.toolbarBand.frame
        print("LIGHTS|\(density.rawValue)|line \(line.centerY)|lights \(center)|band \(root.bounds.maxY - band.midY)")
        #expect(abs(center - line.centerY) <= 0.5, "\(density): lights at \(center), the line at \(line.centerY)")
        #expect(abs((root.bounds.maxY - band.midY) - center) <= 0.5, "\(density): the toolbar band is off the lights' line")
        expectClickable(window, density)
        // A real resize runs AppKit's own titlebar layout after the root's: the lights stay on the line.
        window.setFrame(window.frame.insetBy(dx: -60, dy: -40), display: false)
        window.layoutIfNeeded()
        let resized = try #require(WindowTitlebar.topRowLine(in: window))
        #expect(abs(try lightsCenter(window) - resized.centerY) <= 0.5, "\(density): after a resize the lights left the line")
        expectClickable(window, density)
    }

    /// Every button lies inside each view above it up to the frame view, so a click on any part of it lands.
    private func expectClickable(_ window: NSWindow, _ density: DensityPreset) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            var ancestor = button.superview
            while let view = ancestor, view !== window.contentView?.superview?.superview {
                let frame = button.convert(button.bounds, to: view)
                #expect(view.bounds.contains(frame), "\(density): \(kind.rawValue) at \(frame) outside \(type(of: view)) \(view.bounds)")
                ancestor = view.superview
            }
        }
    }

    /// macOS's own center for the lights: half its titlebar, read from a window nothing has moved.
    private func nativeCenter() -> CGFloat {
        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        bare.isReleasedWhenClosed = false
        defer { bare.close() }
        return (bare.frame.height - bare.contentLayoutRect.maxY) / 2
    }

    /// The lights come back to macOS's place when the row follows them (`chrome.topRowLine` = lights) and when the
    /// tab bars move to the bottom: the line is theirs, or there is none.
    @Test func theLightsGoBackWhereThereIsNoLineOfTheirOwn() throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        TunableStore.shared.register(DesignTunables.all)
        TunableStore.shared.activate(file: nil)
        let key = TopRowLineLook.tunable.key, look = TunableStore.shared.override(key)
        defer {
            TunableStore.shared.set(key, look)
            (design.densityTokens, design.titlebar, design.tabBarPosition) = saved
        }
        design.densityTokens = DensityPreset.spacious.tokens
        design.titlebar = .minimal
        design.tabBarPosition = .top
        TunableStore.shared.set(key, TopRowLineLook.concentric.tunableValue)
        let (window, root) = window()
        defer { window.close() }
        let native = nativeCenter()
        let moved = try lightsCenter(window)
        #expect(moved > native + 1, "Spacious moves the lights down from \(native); they are at \(moved)")
        TunableStore.shared.set(key, TopRowLineLook.lights.tunableValue)
        settle(root)
        #expect(abs(try lightsCenter(window) - native) <= 0.5, "the lights' own line: macOS's place")
        TunableStore.shared.set(key, TopRowLineLook.concentric.tunableValue)
        design.tabBarPosition = .bottom
        settle(root)
        #expect(abs(try lightsCenter(window) - native) <= 0.5, "tab bars at the bottom: macOS's place")
    }
}
