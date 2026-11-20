import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Austin 2026-11-10: "We need to make sure that the traffic lights are aligned to the densities as well
/// (will need to adjust them as well according to which density the user selects)". In a real window the
/// lights center on the top row's line, the line the toolbar band and the tab pills share, at every density;
/// with the `lights` line (the row follows the lights) they stay where macOS puts them.
@MainActor @Suite(.serialized, .closesItsWindows) struct TrafficLightsDensityTests {
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

    /// Lucas 2026-11-17: after switching densities the toggle, Back, Forward and the sidebar's + sat below the traffic
    /// lights ("this seems to only be an issue when switching between densities, sometimes jsut switching back and
    /// forth fixes it"). Measured in a tagged app: the frames were on the line, but after a switch the band had laid
    /// its buttons out from the last density's glyphs (each button draws its new glyph in its own layout, after the
    /// band's). In one window, every switch from one density to another (the sidebar lays the top row out again, then
    /// the window's layout pass runs) leaves the lights, each top-row button's height and line, each glyph's size and
    /// the band's slots where a window opened at that density has them. The sidebar keeps its own width across a
    /// switch (a larger density's controls widen it), so the band's and the +'s x are not compared.
    @Test func everyDensitySwitchDrawsTheTopRowOfAFreshWindow() throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.titlebar = .minimal
        design.tabBarPosition = .top
        // What a window opened at each density draws.
        var fresh: [DensityPreset: [String: CGRect]] = [:]
        for density in DensityPreset.allCases {
            design.densityTokens = density.tokens
            let (window, root) = window()
            fresh[density] = try topRow(window, root)
            window.close()
        }
        design.densityTokens = DensityPreset.compact.tokens
        let (window, root) = window()
        defer { window.close() }
        var current = DensityPreset.compact
        // Every ordered pair: each density switched to from each other one.
        let pairs = DensityPreset.allCases.flatMap { from in DensityPreset.allCases.filter { $0 != from }.map { (from, $0) } }
        for (from, to) in pairs {
            for density in [from, to] where density != current {
                design.densityTokens = density.tokens
                WindowTitlebar.layOutTopRowAgain(in: window)
                window.layoutIfNeeded()
                current = density
            }
            let drawn = try topRow(window, root), want = try #require(fresh[to])
            for (name, rect) in want.sorted(by: { $0.key < $1.key }) {
                #expect(drawn[name] == rect, "\(from) to \(to): \(name) is \(String(describing: drawn[name])), a fresh window's \(rect)")
            }
        }
    }

    /// The top row: the lights' frame; each band button's and the sidebar +'s line (its minY and height, x and width
    /// 0) and glyph size (its image, at the origin); and each band button's place at full presence (its x and width in
    /// the band, y and height 0).
    private func topRow(_ window: NSWindow, _ root: WindowRootView) throws -> [String: CGRect] {
        var out = ["lights": try #require(WindowTitlebar.trafficLightsFrame(in: window))]
        let band = root.toolbarBand
        for (name, button) in [("toggle", band.sidebarToggle), ("back", band.backButton), ("forward", band.forwardButton),
                               ("plus", root.sidebar.sidebarView.newButton)] as [(String, NSButton)] {
            let frame = button.convert(button.bounds, to: nil)
            out[name + " line"] = CGRect(x: 0, y: frame.minY, width: 0, height: frame.height)
            out[name + " glyph"] = CGRect(origin: .zero, size: button.image?.size ?? .zero)
        }
        // Where the band put each button at full presence (its frames scale with the band's presence, which the
        // sidebar's width slide sets): a fresh window's places come from that density's glyphs.
        let presence = band.presence
        try #require(presence > 0.5, "the band is \(presence) shown")
        for (index, button) in [band.sidebarToggle, band.backButton, band.forwardButton].enumerated() {
            out["placed \(index)"] = CGRect(x: (button.frame.minX / presence * 4).rounded() / 4, y: 0,
                                             width: (button.frame.width / presence * 4).rounded() / 4, height: 0)
        }
        return out
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
