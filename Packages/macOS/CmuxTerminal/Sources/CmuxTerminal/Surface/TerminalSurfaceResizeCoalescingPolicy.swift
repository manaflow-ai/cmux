/// Decides whether a surface should defer a same-grid pixel-size update during an interaction.
public struct TerminalSurfaceResizeCoalescingPolicy: Sendable {
    private let windowLiveResizeActive: Bool
    private let interactiveGeometryResizeActive: Bool
    private let bypass: Bool

    /// Creates a policy evaluation for the current resize state.
    ///
    /// - Parameter windowLiveResizeActive: Whether AppKit is tracking a window-edge resize.
    /// - Parameter interactiveGeometryResizeActive: Whether a pane or sidebar geometry transaction is active.
    /// - Parameter bypass: Whether the caller requires the exact candidate size to be applied immediately.
    public init(
        windowLiveResizeActive: Bool,
        interactiveGeometryResizeActive: Bool,
        bypass: Bool
    ) {
        self.windowLiveResizeActive = windowLiveResizeActive
        self.interactiveGeometryResizeActive = interactiveGeometryResizeActive
        self.bypass = bypass
    }

    /// Whether pixel-only surface size changes should be withheld.
    public var shouldCoalescePixelOnlyResize: Bool {
        (windowLiveResizeActive || interactiveGeometryResizeActive) && !bypass
    }
}
