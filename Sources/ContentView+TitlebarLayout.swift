import CoreGraphics

extension ContentView {
    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard isMinimalMode else { return WindowChromeMetrics.appTitlebarHeight }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }

    nonisolated static func customTitlebarLeadingPadding(
        isFullScreen: Bool,
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        titlebarLeadingInset: CGFloat
    ) -> CGFloat {
        if isFullScreen && !isSidebarVisible {
            return 8
        }

        let minimumSidebarTitleInset = max(titlebarLeadingInset, minimumSidebarWidth + 12)
        guard isSidebarVisible else {
            return minimumSidebarTitleInset
        }

        let visibleSidebarTitleInset = sidebarWidth + 12
        // Absorb floating-point drift around the minimum-width clamp.
        guard sidebarWidth > minimumSidebarWidth + 0.5 else {
            return minimumSidebarTitleInset
        }
        return max(titlebarLeadingInset, visibleSidebarTitleInset)
    }

    /// Where the always-visible fullscreen titlebar controls (sidebar toggle,
    /// history, new tab, notifications) are anchored inside the titlebar band.
    struct FullscreenControlsPlacement: Equatable {
        var leadingPadding: CGFloat
        var topPadding: CGFloat
    }

    /// Resolves the placement for the fullscreen titlebar controls, or `nil` when
    /// they should not be shown. The controls are mounted in a single overlay
    /// anchor driven by this function so their on-screen position never depends on
    /// sidebar visibility; toggling the sidebar must not shift the accessory bar.
    nonisolated static func fullscreenControlsPlacement(
        isFullScreen: Bool,
        isSidebarVisible: Bool
    ) -> FullscreenControlsPlacement? {
        guard isFullScreen else { return nil }
        // Placement is intentionally independent of sidebar visibility so toggling
        // the sidebar in fullscreen never shifts the accessory bar. `topPadding`
        // mirrors the title row's top inset (see `customTitlebar`) so the controls'
        // center lines up with the folder icon / title.
        return FullscreenControlsPlacement(leadingPadding: 10, topPadding: 2)
    }
}
