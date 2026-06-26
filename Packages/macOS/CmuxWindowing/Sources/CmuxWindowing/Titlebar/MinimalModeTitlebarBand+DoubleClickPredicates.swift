public import AppKit

extension MinimalModeTitlebarBand {
    /// Reports whether a click should be handled as a minimal-mode titlebar
    /// double-click: it must be a multi-click (`clickCount >= 2`) landing inside
    /// the band built from `isEnabled`, `bounds`, and `topStripHeight`.
    ///
    /// Pure value predicate, faithful lift of the app-side
    /// `shouldHandleMinimalModeTitlebarDoubleClick` free function.
    public static func shouldHandleMinimalModeTitlebarDoubleClick(
        isEnabled: Bool,
        clickCount: Int,
        point: NSPoint,
        bounds: NSRect,
        topStripHeight: CGFloat
    ) -> Bool {
        guard clickCount >= 2 else {
            return false
        }
        return MinimalModeTitlebarBand(
            isEnabled: isEnabled,
            bounds: bounds,
            topStripHeight: topStripHeight
        ).contains(point)
    }

    /// Window-state overload of `shouldHandleMinimalModeTitlebarDoubleClick`: the
    /// band is enabled only when the window is in minimal mode, not full-screen,
    /// and the main window.
    ///
    /// Pure value predicate, faithful lift of the app-side window overload.
    public static func shouldHandleMinimalModeWindowTitlebarDoubleClick(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        isMainWindow: Bool,
        clickCount: Int,
        locationInWindow: NSPoint,
        contentBounds: NSRect,
        titlebarBandHeight: CGFloat
    ) -> Bool {
        shouldHandleMinimalModeTitlebarDoubleClick(
            isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
            clickCount: clickCount,
            point: locationInWindow,
            bounds: contentBounds,
            topStripHeight: titlebarBandHeight
        )
    }

    /// Reports whether a click at `locationInWindow` lands in the minimal-mode
    /// titlebar band (regardless of click count), so it is a candidate for
    /// titlebar click handling. The band is enabled only when the window is in
    /// minimal mode, not full-screen, and the main window.
    ///
    /// Pure value predicate, faithful lift of the app-side window overload.
    public static func isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        isMainWindow: Bool,
        locationInWindow: NSPoint,
        contentBounds: NSRect,
        titlebarBandHeight: CGFloat
    ) -> Bool {
        MinimalModeTitlebarBand(
            isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
            bounds: contentBounds,
            topStripHeight: titlebarBandHeight
        ).contains(locationInWindow)
    }
}
