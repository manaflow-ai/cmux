public import CoreGraphics
import CmuxNextDesign

/// Metrics for the layout. Geometry is a pure function of this value.
///
/// `LayoutModel.style` fills the design-token fields (gap, divider, corner
/// radius) from the live `Metrics` so density and override changes relayout;
/// the defaults here only matter for a style built by hand (tests).
public nonisolated struct LayoutStyle: Hashable, Sendable {
    /// Visible divider thickness between split panes. Token: `Metrics.dividerThickness`.
    public var dividerThickness: CGFloat = 1
    /// Width of the draggable area centered on a divider. Token: `Metrics.dividerHitWidth`.
    public var dividerHitThickness: CGFloat = 7
    /// Gap between columns and at the outer horizontal edges in columns mode. Token: `Metrics.columnGap`.
    public var columnGap: CGFloat = 6
    /// Corner radius of floating layout chrome (drop highlight). Token: `Metrics.panelCornerRadius`.
    public var panelCornerRadius: CGFloat = 10
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

extension LayoutStyle {
    /// This style with its design-token fields replaced by the current
    /// `Metrics` values. Reading it inside an Observation-tracked scope
    /// registers a dependency on `DesignSettings.shared`.
    @MainActor
    public func applyingDesignMetrics() -> LayoutStyle {
        var style = self
        style.dividerThickness = Metrics.dividerThickness
        style.dividerHitThickness = Metrics.dividerHitWidth
        style.columnGap = Metrics.columnGap
        style.panelCornerRadius = Metrics.panelCornerRadius
        return style
    }
}
