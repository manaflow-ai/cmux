import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// R83: Back, Forward and a glass patch under the traffic lights stay hidden
/// until the pointer is over the title bar row or the sidebar, then fade in,
/// in place. `window.titlebarButtons` = always shows them at rest. The
/// sidebar toggle never fades: it is one fixed target after the traffic
/// lights, open or collapsed (Leo, T3 Code ref, 2026-10-07).
@MainActor @Suite(.serialized) struct TitlebarButtonsRevealTests {
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
            #expect(band.sidebarToggle.alphaValue == 1, "the sidebar toggle shows at rest")
            root.titlebarReveal.setPointerInside(true)
            #expect(band.backButton.alphaValue == 1)
            #expect(band.forwardButton.alphaValue == 1)
            #expect(root.trafficLightsGlass.alphaValue == 1)
            #expect(band.sidebarToggle.alphaValue == 1)
            #expect((band.backButton.frame, band.forwardButton.frame) == frames, "the buttons fade in place")
            root.titlebarReveal.setPointerInside(false)
            #expect(band.backButton.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 1)
        }
    }

    /// The pointer over the sidebar shows its chrome: the sidebar's + button and the title bar
    /// buttons above it, as one hover. The toggle shows throughout.
    @Test func hoveringTheSidebarRevealsTheTitlebarButtons() throws {
        try withSettings(.hover) { root in
            let band = root.toolbarBand
            #expect(band.backButton.alphaValue == 0)
            root.sidebar.sidebarView.setChromeRevealed(true)
            #expect(band.sidebarToggle.alphaValue == 1)
            #expect(band.backButton.alphaValue == 1)
            root.sidebar.sidebarView.setChromeRevealed(false)
            #expect(band.backButton.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 1)
        }
    }

    @Test func alwaysModeShowsTheButtonsAtRest() throws {
        try withSettings(.always) { root in
            #expect(root.toolbarBand.backButton.alphaValue == 1)
            #expect(root.toolbarBand.forwardButton.alphaValue == 1)
            #expect(root.trafficLightsGlass.alphaValue == 0, "the glass patch is a hover cue only")
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

