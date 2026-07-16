extension TerminalSurface {
    /// Returns whether same-grid pixel changes should be coalesced for the current resize interaction.
    ///
    /// - Parameter windowLiveResizeActive: Whether AppKit is tracking a window-edge resize.
    /// - Parameter interactiveGeometryResizeActive: Whether a pane or sidebar geometry transaction is active.
    /// - Parameter bypass: Whether the caller requires the exact candidate size to be applied immediately.
    /// - Returns: `true` when pixel-only surface size changes should be withheld.
    public static func shouldCoalesceSurfacePixelResize(
        windowLiveResizeActive: Bool,
        interactiveGeometryResizeActive: Bool,
        bypass: Bool
    ) -> Bool {
        (windowLiveResizeActive || interactiveGeometryResizeActive) && !bypass
    }
}
