public import CoreGraphics

/// Metrics for the layout. Defaults match the cmux-next visual rules.
public nonisolated struct LayoutStyle: Hashable, Sendable {
    /// Visible divider thickness between split panes.
    public var dividerThickness: CGFloat = 1
    /// Width of the draggable area centered on a divider.
    public var dividerHitThickness: CGFloat = 9
    /// Gap between columns and at the outer horizontal edges in columns mode.
    public var columnGap: CGFloat = 8
    /// Smallest pane extent the divider drag allows along its axis.
    public var minimumPaneExtent: CGFloat = 48
    /// Focus ring stroke width.
    public var focusRingWidth: CGFloat = 1
    /// Inactive pane dim amount when `LayoutModel.dimsInactivePanes` is on.
    public var inactivePaneDimming: CGFloat = 0.14
    /// Fraction of a pane's extent that counts as an edge drop zone.
    public var dropEdgeFraction: CGFloat = 0.28
    /// Clamp for the edge drop band.
    public var dropEdgeRange: ClosedRange<CGFloat> = 28...180
    /// Width of the "new column" drop zone centered on each column gap.
    public var newColumnDropWidth: CGFloat = 36

    public init() {}
}
