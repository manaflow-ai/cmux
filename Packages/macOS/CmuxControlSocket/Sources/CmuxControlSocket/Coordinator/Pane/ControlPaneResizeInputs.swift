public import Foundation

/// The pre-parsed inputs `pane.resize` carries, as ``ControlCommandCoordinator``
/// hands them to ``ControlPaneContext``.
///
/// The coordinator parses each value (mirroring the legacy `v2*` parsing) and
/// performs the present-but-invalid validation that returns `invalid_params`;
/// the seam runs the split-tree candidate collection and the divider mutation.
public struct ControlPaneResizeInputs: Sendable, Equatable {
    /// The explicit `pane_id` target, if any; the seam falls back to the focused
    /// pane when absent.
    public let paneID: UUID?
    /// The lowercased `absolute_axis` (`horizontal`/`vertical`), if the request
    /// took the absolute-resize path.
    public let absoluteAxis: String?
    /// The requested outer pane extent in native points, carried under the
    /// historical `target_pixels` wire key.
    public let targetPixels: Double?
    /// Exact tmux grid cells accompanying `target_pixels` when a compatibility
    /// adapter already owns the cell-space intent.
    public let targetCells: Int?
    /// The lowercased `direction` (`left|right|up|down`), if the request took the
    /// relative-resize path.
    public let direction: String?
    /// The relative-resize delta in native points (defaulting to 1, as the legacy body did).
    public let amount: Int
    /// Exact tmux cell delta accompanying `amount` from a compatibility adapter.
    public let amountCells: Int?
    /// Whether the request carries native tmux adjustment semantics instead of
    /// the public border-oriented `pane.resize` direction semantics.
    public let tmuxCompatibility: Bool

    /// Creates the pane-resize inputs.
    ///
    /// - Parameters:
    ///   - paneID: The explicit `pane_id` target, if any.
    ///   - absoluteAxis: The lowercased absolute axis, if present.
    ///   - targetPixels: The requested outer pane extent in native points.
    ///   - targetCells: The compatibility adapter's exact tmux cell target.
    ///   - direction: The lowercased relative direction, if present.
    ///   - amount: The relative delta in native points.
    ///   - amountCells: The compatibility adapter's exact tmux cell delta.
    ///   - tmuxCompatibility: Whether to preserve native tmux resize semantics.
    public init(
        paneID: UUID?,
        absoluteAxis: String?,
        targetPixels: Double?,
        targetCells: Int?,
        direction: String?,
        amount: Int,
        amountCells: Int?,
        tmuxCompatibility: Bool
    ) {
        self.paneID = paneID
        self.absoluteAxis = absoluteAxis
        self.targetPixels = targetPixels
        self.targetCells = targetCells
        self.direction = direction
        self.amount = amount
        self.amountCells = amountCells
        self.tmuxCompatibility = tmuxCompatibility
    }
}
