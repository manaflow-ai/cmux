import CoreGraphics
import Testing
@testable import CmuxAppKitSupportUI

/// Behavior of the pure titlebar layout policy lifted from `ContentView`.
@Suite struct WindowTitlebarLayoutTests {
    private let layout = WindowTitlebarLayout()

    @Test func standardModeReservesFullTitlebarHeight() {
        let padding = layout.effectiveTitlebarPadding(
            isMinimalMode: false,
            isFullScreen: false,
            appTitlebarHeight: 28,
            titlebarPadding: 12,
            hostingSafeAreaTop: 8
        )
        #expect(padding == 28)
    }

    @Test func minimalFullscreenReservesNothing() {
        let padding = layout.effectiveTitlebarPadding(
            isMinimalMode: true,
            isFullScreen: true,
            appTitlebarHeight: 28,
            titlebarPadding: 12,
            hostingSafeAreaTop: 8
        )
        #expect(padding == 0)
    }

    @Test func minimalWindowedCancelsReportedSafeArea() {
        let padding = layout.effectiveTitlebarPadding(
            isMinimalMode: true,
            isFullScreen: false,
            appTitlebarHeight: 28,
            titlebarPadding: 12,
            hostingSafeAreaTop: 8
        )
        // -max(0, min(12, 8)) == -8
        #expect(padding == -8)
    }

    @Test func fullscreenHiddenSidebarUsesFixedInset() {
        let inset = layout.customTitlebarLeadingPadding(
            isFullScreen: true,
            isSidebarVisible: false,
            sidebarWidth: 200,
            minimumSidebarWidth: 160,
            titlebarLeadingInset: 12
        )
        #expect(inset == 8)
    }

    @Test func visibleSidebarFlowsTitleToTheRight() {
        let inset = layout.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 200,
            minimumSidebarWidth: 160,
            titlebarLeadingInset: 12
        )
        // sidebarWidth + 12, clamped against the leading inset.
        #expect(inset == 212)
    }

    @Test func minimumWidthSidebarFallsBackToMinimumInset() {
        let inset = layout.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 160,
            minimumSidebarWidth: 160,
            titlebarLeadingInset: 12
        )
        // sidebarWidth not > minimumSidebarWidth + 0.5 -> max(12, 160 + 12)
        #expect(inset == 172)
    }

    @Test func placementIsNilOutsideFullscreen() {
        #expect(layout.fullscreenControlsPlacement(isFullScreen: false, isSidebarVisible: true) == nil)
        #expect(layout.fullscreenControlsPlacement(isFullScreen: false, isSidebarVisible: false) == nil)
    }

    @Test func placementIsIndependentOfSidebarVisibility() {
        let visible = layout.fullscreenControlsPlacement(isFullScreen: true, isSidebarVisible: true)
        let hidden = layout.fullscreenControlsPlacement(isFullScreen: true, isSidebarVisible: false)
        #expect(visible != nil)
        #expect(visible == hidden)
        #expect(visible == FullscreenControlsPlacement(leadingPadding: 10, topPadding: 2))
    }
}
