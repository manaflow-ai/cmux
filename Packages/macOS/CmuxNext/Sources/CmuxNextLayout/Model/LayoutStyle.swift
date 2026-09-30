public import CoreGraphics
import CmuxNextDesign

/// Metrics for the layout. Geometry is a pure function of this value.
///
/// `LayoutModel.style` fills the design-token fields (gap, divider, corner
/// radius, pane chrome height) from the live `Metrics` so density and override changes relayout;
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
    /// Chrome every pane draws above its content (the tab strip). Token:
    /// `Metrics.tabStripHeight`, so the minimum pane height follows density.
    public var paneChromeHeight: CGFloat = 28
    /// Smallest content area a pane keeps below its chrome: about 25 columns
    /// by 4 rows of a 13 pt terminal cell (8 x 16 pt). The width also keeps
    /// one tab plus the strip's trailing buttons visible (a 96 pt pane showed
    /// only the buttons). Split geometry, divider drags, column widths and
    /// the split room check all honor it.
    public var minimumPaneContentSize = CGSize(width: 200, height: 64)
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

    /// Smallest frame a pane gets while its screen has room: the minimum
    /// content area plus the chrome above it.
    public var minimumPaneSize: CGSize {
        CGSize(width: minimumPaneContentSize.width, height: paneChromeHeight + minimumPaneContentSize.height)
    }
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
        style.paneChromeHeight = Metrics.tabStripHeight
        return style
    }
}
