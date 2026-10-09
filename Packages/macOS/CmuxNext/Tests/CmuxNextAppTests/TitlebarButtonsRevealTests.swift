import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// R83: Back, Forward and a glass patch under the traffic lights stay hidden
/// until the pointer is over the title bar row or the sidebar, then fade in,
/// in place. `window.titlebarButtons` = always shows them at rest. The
/// sidebar toggle joins them (cx-uxdr, Lawrence 2026-10-08: "toggle sidebar
/// button should hide when im not hovered on sidebar"): it shows only while
/// the pointer is over the sidebar or the top row above it, or while one of
/// the buttons has keyboard focus. It stays in the accessibility tree.
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
            #expect(band.sidebarToggle.alphaValue == 0, "the sidebar toggle hides at rest")
            #expect(!band.sidebarToggle.isHidden, "a clear toggle (alpha 0, not hidden) stays in the accessibility tree")
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
    /// buttons above it, the toggle included, as one hover.
    @Test func hoveringTheSidebarRevealsTheTitlebarButtons() throws {
        try withSettings(.hover) { root in
            let band = root.toolbarBand
            #expect(band.backButton.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 0)
            root.sidebar.sidebarView.setChromeRevealed(true)
            #expect(band.sidebarToggle.alphaValue == 1)
            #expect(band.backButton.alphaValue == 1)
            root.sidebar.sidebarView.setChromeRevealed(false)
            #expect(band.backButton.alphaValue == 0)
            #expect(band.sidebarToggle.alphaValue == 0)
        }
    }

    @Test func alwaysModeShowsTheButtonsAtRest() throws {
        try withSettings(.always) { root in
            #expect(root.toolbarBand.backButton.alphaValue == 1)
            #expect(root.toolbarBand.forwardButton.alphaValue == 1)
            #expect(root.toolbarBand.sidebarToggle.alphaValue == 1)
            #expect(root.trafficLightsGlass.alphaValue == 0, "the glass patch is a hover cue only")
        }
    }

    /// The reveal region is the top row above the sidebar (and the band),
    /// not the whole row: hovering the tab strip over the content does not
    /// show the toggle.
    @Test func theRegionSpansTheTopRowAboveTheSidebar() throws {
        try withSettings(.hover) { root in
            let region = root.titlebarRevealRegion.frame
            #expect(region.minX == 0 && region.maxX >= root.sidebar.frame.maxX && region.maxX >= root.toolbarBand.frame.maxX)
            #expect(region.width < root.bounds.width, "the content's top row is outside the region")
            #expect(region.maxY == root.bounds.maxY)
            #expect(region.height >= TitlebarBandButton.side)
        }
    }
}

