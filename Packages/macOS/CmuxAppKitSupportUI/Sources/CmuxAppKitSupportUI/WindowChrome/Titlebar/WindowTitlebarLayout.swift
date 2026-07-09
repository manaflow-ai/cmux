public import CoreGraphics

/// Pure layout policy for the cmux custom titlebar band.
///
/// Owns the geometry decisions that the window-shell render path reads every
/// frame: how far the title content insets behind the sidebar, where the
/// always-visible fullscreen controls anchor, and how much top padding the
/// content area reserves for the titlebar. Every method is a pure value
/// transform over its inputs, so the same instance can be shared across windows
/// and exercised directly in tests without a live `NSWindow`.
///
/// This is a real value type with instance methods (not a static namespace):
/// the window-chrome composition holds one and forwards to it, keeping the
/// titlebar policy in one place beside the rest of the chrome primitives.
public struct WindowTitlebarLayout: Sendable {
    /// Creates a titlebar layout policy.
    public init() {}

    /// Top padding the content area reserves for the titlebar.
    ///
    /// Standard mode always reserves the full chrome height. Minimal mode
    /// reserves nothing in fullscreen, and otherwise cancels the AppKit-reported
    /// safe-area inset so the content sits flush under the custom band.
    ///
    /// - Parameters:
    ///   - isMinimalMode: Whether the window uses the minimal presentation mode.
    ///   - isFullScreen: Whether the window is in macOS fullscreen.
    ///   - appTitlebarHeight: The cmux custom titlebar height to reserve in standard mode.
    ///   - titlebarPadding: The native titlebar inset reported by AppKit.
    ///   - hostingSafeAreaTop: The top safe-area inset reported by the hosting view.
    /// - Returns: The vertical padding to apply above the content area.
    public func effectiveTitlebarPadding(
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

    /// Leading inset for the custom titlebar's title content.
    ///
    /// Keeps the title clear of the traffic lights and the sidebar: it flows to
    /// the right of the sidebar when visible, and otherwise reserves at least the
    /// minimum sidebar width so the title never overlaps the traffic lights.
    ///
    /// - Parameters:
    ///   - isFullScreen: Whether the window is in macOS fullscreen.
    ///   - isSidebarVisible: Whether the left sidebar is shown.
    ///   - sidebarWidth: The current sidebar width.
    ///   - minimumSidebarWidth: The minimum allowed sidebar width.
    ///   - titlebarLeadingInset: The AppKit-reported traffic-light leading inset.
    /// - Returns: The leading padding for the title content.
    public func customTitlebarLeadingPadding(
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
    /// controls (sidebar toggle, history, new tab, notifications), or `nil` when
    /// they should not be shown.
    ///
    /// The controls mount in a single overlay anchor driven by this value so
    /// their on-screen position never depends on sidebar visibility; toggling the
    /// sidebar in fullscreen must not shift the accessory bar. `topPadding`
    /// mirrors the title row's top inset so the controls' center lines up with
    /// the folder icon / title.
    ///
    /// - Parameters:
    ///   - isFullScreen: Whether the window is in macOS fullscreen.
    ///   - isSidebarVisible: Whether the left sidebar is shown.
    /// - Returns: The placement, or `nil` when the controls are not shown.
    public func fullscreenControlsPlacement(
        isFullScreen: Bool,
        isSidebarVisible: Bool
    ) -> FullscreenControlsPlacement? {
        guard isFullScreen else { return nil }
        return FullscreenControlsPlacement(leadingPadding: 10, topPadding: 2)
    }
}

/// Anchor for the always-visible fullscreen titlebar controls inside the band.
public struct FullscreenControlsPlacement: Equatable, Sendable {
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
