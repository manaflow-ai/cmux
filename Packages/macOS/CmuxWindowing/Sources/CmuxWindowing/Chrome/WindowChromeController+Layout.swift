public import CoreGraphics

/// Pure titlebar layout math for the window-chrome cluster.
///
/// These were `ContentView` statics that forwarded to
/// `CmuxAppKitSupportUI.WindowTitlebarLayout`. `CmuxWindowing` cannot depend on
/// `CmuxAppKitSupportUI` (that would close a cycle through
/// `CmuxWorkspaces -> CmuxWindowing`), so the value transforms are lifted here
/// byte-faithfully. Every method is a pure function of its inputs.
extension WindowChromeController {
    /// Top padding the content area reserves for the titlebar.
    ///
    /// Standard mode always reserves the full chrome height. Minimal mode
    /// reserves nothing in fullscreen and otherwise cancels the AppKit-reported
    /// safe-area inset so the content sits flush under the custom band.
    public nonisolated static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        appTitlebarHeight: CGFloat,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard isMinimalMode else { return appTitlebarHeight }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }

    /// Leading inset for the custom titlebar's title content. Keeps the title
    /// clear of the traffic lights and the sidebar.
    public nonisolated static func customTitlebarLeadingPadding(
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

    /// Resolves the placement for the always-visible fullscreen titlebar
    /// controls, or `nil` when they should not be shown.
    public nonisolated static func fullscreenControlsPlacement(
        isFullScreen: Bool,
        isSidebarVisible: Bool
    ) -> WindowFullscreenControlsPlacement? {
        guard isFullScreen else { return nil }
        return WindowFullscreenControlsPlacement(leadingPadding: 10, topPadding: 2)
    }

    /// Instance convenience: the effective titlebar padding for the controller's
    /// current measured insets.
    public func effectiveTitlebarPadding(isMinimalMode: Bool) -> CGFloat {
        Self.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            appTitlebarHeight: WindowChromeLayoutMetrics.appTitlebarHeight,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }
}

/// Anchor for the always-visible fullscreen titlebar controls inside the band.
///
/// Package-local mirror of `CmuxAppKitSupportUI.FullscreenControlsPlacement`
/// (unreachable from this package without a dependency cycle).
public struct WindowFullscreenControlsPlacement: Equatable, Sendable {
    /// Leading padding from the band's leading edge.
    public var leadingPadding: CGFloat

    /// Top padding from the band's top edge.
    public var topPadding: CGFloat

    /// Creates a fullscreen controls placement.
    public init(leadingPadding: CGFloat, topPadding: CGFloat) {
        self.leadingPadding = leadingPadding
        self.topPadding = topPadding
    }
}
