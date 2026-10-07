import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// R83: the title bar buttons (the sidebar toggle, Back and Forward) and a
/// glass patch under the traffic lights stay hidden until the pointer is
/// over the title bar row or the sidebar, then fade in, in place (Lawrence
/// 2026-10-05: "sidebar button should fade"; before, the toggle never
/// faded). `window.titlebarButtons` = always shows them at rest.
@MainActor @Suite(.serialized) struct TitlebarButtonsRevealTests {
    final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func withSettings(_ mode: TitlebarButtonsMode, _ body: (WindowRootView) throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = (design.titlebarButtons, design.animationSpeed)
        defer { (design.titlebarButtons, design.animationSpeed) = saved }
        design.animationSpeed = .off
        design.titlebarButtons = mode
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()), reduceTransparency: { false },
                                  applyWindowBlur: { _, _ in })
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        root.layoutSubtreeIfNeeded()
        try body(root)
    }

    @Test func hoverModeHidesHistoryButtonsUntilTheRowIsHovered() throws {
        try withSettings(.hover) { root in
            let band = root.toolbarBand
            let frames = (band.backButton.frame, band.forwardButton.frame)
            #expect(band.backButton.alphaValue == 0)
            #expect(band.forwardButton.alphaValue == 0)
            #expect(root.trafficLightsGlass.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 0, "the sidebar toggle fades with Back and Forward")
            root.titlebarReveal.setPointerInside(true)
            #expect(band.backButton.alphaValue == 1)
            #expect(band.forwardButton.alphaValue == 1)
            #expect(root.trafficLightsGlass.alphaValue == 1)
            #expect(band.sidebarToggle.alphaValue == 1)
            #expect((band.backButton.frame, band.forwardButton.frame) == frames, "the buttons fade in place")
            root.titlebarReveal.setPointerInside(false)
            #expect(band.backButton.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 0)
        }
    }

    /// The pointer over the sidebar shows its chrome: the sidebar's + button and the title bar
    /// buttons above it (the toggle first), as one hover.
    @Test func hoveringTheSidebarRevealsTheTitlebarButtons() throws {
        try withSettings(.hover) { root in
            let band = root.toolbarBand
            #expect(band.sidebarToggle.alphaValue == 0)
            root.sidebar.sidebarView.setChromeRevealed(true)
            #expect(band.sidebarToggle.alphaValue == 1, "sidebar hover reveals the toggle")
            #expect(band.backButton.alphaValue == 1)
            root.sidebar.sidebarView.setChromeRevealed(false)
            #expect(band.sidebarToggle.alphaValue == 0)
        }
    }

    /// Keyboard focus on the toggle reveals it (no hidden-but-focusable trap), with the sidebar
    /// hidden too; the traffic lights show throughout.
    @Test func focusOnTheToggleRevealsIt() throws {
        try withSettings(.hover) { root in
            let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.contentView = root
            root.sidebarHidden = true
            #expect(root.toolbarBand.sidebarToggle.alphaValue == 0)
            let toggle = root.toolbarBand.sidebarToggle
            // Stands in for the button's own focus under Full Keyboard Access (a test host has it off).
            let focus = FocusableView(frame: toggle.bounds)
            toggle.addSubview(focus)
            defer { focus.removeFromSuperview() }
            #expect(window.makeFirstResponder(focus))
            #expect(toggle.alphaValue == 1)
            #expect(window.standardWindowButton(.closeButton)?.alphaValue == 1, "the traffic lights never fade")
        }
    }

    @Test func alwaysModeShowsTheButtonsAtRest() throws {
        try withSettings(.always) { root in
            #expect(root.toolbarBand.backButton.alphaValue == 1)
            #expect(root.toolbarBand.forwardButton.alphaValue == 1)
            #expect(root.trafficLightsGlass.alphaValue == 0, "the glass patch is a hover cue only")
        }
    }

    /// The band's buttons hover like the sidebar's icon buttons next to them
    /// (TRAFFIC-LIGHTS-ALWAYS-AND-CLEAN-SIDEBAR-TOGGLE: a quiet hover, one family). Before, no
    /// pointer event reached their hover, so it never showed.
    @Test func aBandButtonTakesTheChromeHover() throws {
        try withSettings(.always) { root in
            for button in [root.toolbarBand.sidebarToggle, root.toolbarBand.backButton] {
                let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                                  windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                                 windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                button.mouseEntered(with: entered)
                #expect(button.hover.state.hovering, "the pointer over a band button shows the hover")
                button.mouseExited(with: exited)
                #expect(!button.hover.state.hovering)
            }
        }
    }

    /// The glyph sits on whole device pixels at 1x and 2x, centered within half a pixel, so its
    /// strokes stay crisp (AppKit centers an odd 17 x 13 symbol in a 22 pt button on a half point).
    @Test(arguments: [CGFloat(1), 2]) func theBandGlyphSitsOnWholePixels(scale: CGFloat) {
        for size in [CGSize(width: 17, height: 13), CGSize(width: 8.5, height: 13.5)] {
            let rect = TitlebarBandButton.glyphRect(size, side: 22, scale: scale)
            #expect((rect.minX * scale).rounded() == rect.minX * scale && (rect.minY * scale).rounded() == rect.minY * scale, "\(rect) at \(scale)x")
            #expect(abs(rect.midX - 11) <= 0.5 / scale && abs(rect.midY - 11) <= 0.5 / scale)
        }
    }

    /// The reveal region is the whole top row, not just the buttons.
    @Test func theRegionSpansTheTopRow() throws {
        try withSettings(.hover) { root in
            let region = root.titlebarRevealRegion.frame
            #expect(region.minX == 0 && region.width == root.bounds.width)
            #expect(region.maxY == root.bounds.maxY)
            #expect(region.height >= TitlebarBandButton.side)
        }
    }
}

