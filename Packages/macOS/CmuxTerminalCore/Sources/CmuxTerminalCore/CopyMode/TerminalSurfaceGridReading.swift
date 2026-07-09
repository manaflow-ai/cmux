public import CoreGraphics

/// Ghostty's IME caret point, expressed in the host view's top-origin coordinates.
///
/// ``TerminalKeyboardCopyModeController`` reads this when copy mode starts to seed
/// the initial cursor from the live terminal caret.
public struct TerminalSurfaceIMEPoint: Equatable, Sendable {
    /// The caret X coordinate at the cell midpoint.
    public let x: Double
    /// The caret top-origin Y coordinate.
    public let y: Double

    /// Creates an IME caret point.
    ///
    /// - Parameters:
    ///   - x: The caret X coordinate at the cell midpoint.
    ///   - y: The caret top-origin Y coordinate.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The host seam that feeds live `ghostty_surface_t` geometry and side effects to
/// ``TerminalKeyboardCopyModeController``.
///
/// The controller owns the copy-mode state machine but performs no Ghostty C calls
/// and holds no AppKit views. Every read of the live grid, every binding-action
/// send, every synthetic-selection effect, and the overlay render is routed back to
/// the host (the live `GhosttyNSView`) through this protocol. This keeps the latency
/// sensitive `ghostty_surface_t` reads and NSView coordinate conversion app-side
/// while the mode state and decisions live in the package.
///
/// The host is held weakly by the controller and all members are `@MainActor`.
@MainActor
public protocol TerminalSurfaceGridReading: AnyObject {
    /// Whether the host currently has a live `ghostty_surface_t`.
    func copyModeHasSurface() -> Bool

    /// Builds the current grid-metrics snapshot, or `nil` when geometry is unusable.
    func copyModeGridMetrics() -> TerminalKeyboardCopyModeGridMetrics?

    /// The current viewport row count, used as a fallback when metrics are unavailable.
    func copyModeViewportRowCount() -> Int

    /// The current viewport column count, used as a fallback when metrics are unavailable.
    func copyModeViewportColumnCount() -> Int

    /// Ghostty's live IME caret point, or `nil` when unavailable.
    func copyModeIMEPoint() -> TerminalSurfaceIMEPoint?

    /// The current scrollbar offset in scrollback lines, or `nil` when unavailable.
    func copyModeScrollbarOffset() -> UInt64?

    /// The total scrollback height in rows, or `nil` when unavailable.
    func copyModeScrollbarTotal() -> UInt64?

    /// The visible scrollbar length in rows, or `nil` when unavailable.
    func copyModeScrollbarVisibleLength() -> UInt64?

    /// Sends a Ghostty binding action to the live surface.
    ///
    /// - Parameter action: The binding-action string (e.g. `"copy_to_clipboard"`).
    /// - Returns: Whether Ghostty consumed the action.
    @discardableResult
    func copyModePerformBindingAction(_ action: String) -> Bool

    /// Clears the live surface selection.
    func copyModeClearSelection()

    /// Whether the live runtime currently reports a selectable range.
    func copyModeHasRuntimeSelection() -> Bool

    /// Synthesizes a single-cell selection at the cursor.
    ///
    /// - Parameters:
    ///   - metrics: The grid snapshot the cursor was resolved against.
    ///   - cursor: The (already clamped) cursor cell to select.
    /// - Returns: Whether the cell was selected.
    func copyModeSelectCursorCell(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        cursor: TerminalKeyboardCopyModeCursor
    ) -> Bool

    /// Synthesizes a viewport-line selection without copying it.
    ///
    /// - Parameters:
    ///   - metrics: The grid snapshot to position the drag against.
    ///   - startRow: The first viewport row to select.
    ///   - lineCount: The number of viewport lines to select.
    /// - Returns: Whether the runtime selection was created.
    func copyModeSelectViewportLines(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        startRow: Int,
        lineCount: Int
    ) -> Bool

    /// Copies the runtime's current selection to the standard clipboard.
    ///
    /// - Returns: Whether copying succeeded.
    func copyModeCopyCurrentSelectionToClipboard() -> Bool

    /// Copies an absolute-row visual-line selection to the standard clipboard.
    ///
    /// - Parameters:
    ///   - selection: The linewise selection tracked by the controller.
    ///   - metrics: The grid snapshot used to bound the runtime text read.
    ///   - maxBytes: The maximum formatted byte count to copy through the fallback path.
    /// - Returns: Whether copying succeeded.
    func copyModeCopyVisualLineSelection(
        _ selection: TerminalKeyboardCopyModeVisualLineSelection,
        metrics: TerminalKeyboardCopyModeGridMetrics,
        maxBytes: UInt
    ) -> Bool

    /// Copies a run of viewport lines to the clipboard via a synthetic drag.
    ///
    /// - Parameters:
    ///   - metrics: The grid snapshot to position the drag against.
    ///   - startRow: The first viewport row to copy.
    ///   - lineCount: The number of lines to copy.
    /// - Returns: Whether the copy succeeded.
    func copyModeCopyViewportLines(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        startRow: Int,
        lineCount: Int
    ) -> Bool

    /// Renders (or hides) the copy-mode cursor overlay.
    ///
    /// - Parameter rect: The overlay rect in AppKit coordinates, or `nil` to hide it.
    func copyModeApplyCursorOverlay(rect: CGRect?)

    /// Flushes any pending scrollbar update, returning whether one was applied.
    @discardableResult
    func copyModeFlushPendingScrollbarIfAvailable() -> Bool

    /// Schedules the deferred viewport-jump cursor-sync fallback for a generation.
    ///
    /// The host arranges for ``TerminalKeyboardCopyModeController/previewViewportJumpCursorSyncIfNeeded(generation:)``
    /// and ``TerminalKeyboardCopyModeController/expireViewportJumpCursorSyncIfNeeded(generation:)``
    /// to be invoked after the preview and expiry delays.
    ///
    /// - Parameter generation: The viewport-jump generation to schedule for.
    func copyModeScheduleViewportJumpFallback(generation: Int)

    /// Notifies the host that copy-mode active state changed (to mirror onto the surface model).
    ///
    /// - Parameter active: The new active state.
    func copyModeActiveDidChange(_ active: Bool)
}
