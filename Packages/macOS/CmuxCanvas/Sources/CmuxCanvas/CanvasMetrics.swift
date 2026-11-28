import Foundation

/// User-configurable layout metrics shared by every canvas operation.
///
/// There is exactly one canonical gap: snapping, alignment, distribution, and
/// new-pane placement all read ``gap`` so the canvas feels uniformly spaced
/// regardless of which operation produced a frame.
public struct CanvasMetrics: Hashable, Codable, Sendable {
    /// The canonical spacing between pane edges, in canvas points.
    public var gap: Double
    /// Maximum distance at which a dragged or resized edge snaps to a target.
    public var snapThreshold: Double
    /// The smallest size a pane may be resized to.
    public var minPaneSize: CanvasSize

    /// The default gap in points used when the user has not configured one.
    public static let defaultGap: Double = 16
    /// The default snap threshold in points.
    public static let defaultSnapThreshold: Double = 8
    /// The default minimum pane size.
    public static let defaultMinPaneSize = CanvasSize(width: 200, height: 120)

    /// Creates metrics.
    ///
    /// - Parameters:
    ///   - gap: Canonical spacing between pane edges. Defaults to ``defaultGap``.
    ///   - snapThreshold: Snap capture distance. Defaults to ``defaultSnapThreshold``.
    ///   - minPaneSize: Minimum pane size. Defaults to ``defaultMinPaneSize``.
    public init(
        gap: Double = CanvasMetrics.defaultGap,
        snapThreshold: Double = CanvasMetrics.defaultSnapThreshold,
        minPaneSize: CanvasSize = CanvasMetrics.defaultMinPaneSize
    ) {
        self.gap = gap
        self.snapThreshold = snapThreshold
        self.minPaneSize = minPaneSize
    }
}
