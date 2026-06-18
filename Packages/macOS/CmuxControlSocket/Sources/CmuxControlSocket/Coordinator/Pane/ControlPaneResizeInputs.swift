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
    /// The `target_pixels` for the absolute-resize path, if present.
    public let targetPixels: Double?
    /// The lowercased `direction` (`left|right|up|down`), if the request took the
    /// relative-resize path.
    public let direction: String?
    /// The relative-resize `amount` (defaulting to 1, as the legacy body did).
    public let amount: Int

    /// Creates the pane-resize inputs.
    ///
    /// - Parameters:
    ///   - paneID: The explicit `pane_id` target, if any.
    ///   - absoluteAxis: The lowercased absolute axis, if present.
    ///   - targetPixels: The absolute target pixels, if present.
    ///   - direction: The lowercased relative direction, if present.
    ///   - amount: The relative amount.
    public init(
        paneID: UUID?,
        absoluteAxis: String?,
        targetPixels: Double?,
        direction: String?,
        amount: Int
    ) {
        self.paneID = paneID
        self.absoluteAxis = absoluteAxis
        self.targetPixels = targetPixels
        self.direction = direction
        self.amount = amount
    }
}
