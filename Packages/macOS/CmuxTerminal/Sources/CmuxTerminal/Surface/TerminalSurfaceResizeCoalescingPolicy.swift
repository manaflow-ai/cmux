/// Decides when a terminal surface may defer a same-grid pixel-size update.
public struct TerminalSurfaceResizeCoalescingPolicy: Sendable {
    /// Identifies which side owns the terminal's process and resize protocol.
    public enum SurfaceKind: Sendable {
        /// Ghostty owns a child process and its PTY. A pixel-only resize would
        /// still issue `TIOCSWINSZ` and deliver `SIGWINCH`, even when the cell
        /// grid is unchanged.
        case processOwned

        /// cmux supplies the bytes for a remote/manual mirror. Pixel samples
        /// remain observable outside interactions because they calibrate the
        /// mirror's feed-forward geometry.
        case manualIO
    }

    private let windowLiveResizeActive: Bool
    private let interactiveGeometryResizeActive: Bool
    private let bypass: Bool
    private let surfaceKind: SurfaceKind

    /// Creates a policy evaluation for the current resize state.
    ///
    /// - Parameter windowLiveResizeActive: Whether AppKit is tracking a window-edge resize.
    /// - Parameter interactiveGeometryResizeActive: Whether a pane or sidebar geometry transaction is active.
    /// - Parameter bypass: Whether the caller requires the exact candidate size to be applied immediately.
    /// - Parameter surfaceKind: Whether Ghostty owns a process PTY or cmux is
    ///   rendering a manual-I/O mirror. Process-owned surfaces coalesce stable
    ///   grid pixel churn even outside an interaction; manual-I/O surfaces keep
    ///   their previous interaction-only behavior so geometry calibration sees
    ///   every applied sample.
    public init(
        windowLiveResizeActive: Bool,
        interactiveGeometryResizeActive: Bool,
        bypass: Bool,
        surfaceKind: SurfaceKind
    ) {
        self.windowLiveResizeActive = windowLiveResizeActive
        self.interactiveGeometryResizeActive = interactiveGeometryResizeActive
        self.bypass = bypass
        self.surfaceKind = surfaceKind
    }

    /// Whether pixel-only surface size changes should be withheld.
    public var shouldCoalescePixelOnlyResize: Bool {
        guard !bypass else { return false }
        switch surfaceKind {
        case .processOwned:
            // Ghostty's combined renderer/PTY resize API turns a harmless
            // pixel jitter into a SIGWINCH. Keep the semantic cell grid
            // stable until a candidate can actually change that grid.
            return true
        case .manualIO:
            return windowLiveResizeActive || interactiveGeometryResizeActive
        }
    }
}
