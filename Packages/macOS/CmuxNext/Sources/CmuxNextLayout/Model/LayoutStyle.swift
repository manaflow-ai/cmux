public import CoreGraphics
public import CmuxNextDesign

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
    /// Inset between a pane's cell and its rounded content rect (tab strip
    /// plus content). Token: `Metrics.panePadding`. 0 is edge to edge.
    public var panePadding: CGFloat = 0
    /// Corner radius of the pane content rect. Token: `Metrics.paneCornerRadius`.
    public var paneCornerRadius: CGFloat = 0
    /// Draws the hairline pane border (`layout.paneBorder` = subtle). While
    /// it shows, split dividers draw no line: the borders separate panes.
    public var showsPaneBorder = false
    /// Divider lines and every other line draw (`appearance.borders`).
    public var drawsLines = true
    /// The focus ring (`focusRing.*`). Drawn in the overlay plane only.
    public var focusRing = FocusRingSettings()
    /// The attention ring of panes with an unread notification
    /// (`notifications.attention.*`).
    public var attention = AttentionSettings()
    /// Border color override (`layout.paneBorderColor`); nil is the theme's.
    public var paneBorderColor: ThemeRGB?
    /// Border width in points (`layout.paneBorderWidth`); nil is one device pixel.
    public var paneBorderWidth: CGFloat?
    /// Inactive pane dim amount when `LayoutModel.dimsInactivePanes` is on.
    public var inactivePaneDimming: CGFloat = 0.14
    /// Debug Settings `focus.ringAlpha`: the ring's foreground share in place
    /// of `focusRing.contrast`; nil follows the setting. Read here, in the
    /// observed style, so a slider move repaints the ring at once.
    public var focusRingAlphaOverride: CGFloat?
    /// `appearance.focusIndicator`, and how unfocused panes' tabs draw
    /// subtler when it marks tabs (`ChromeEmphasis.forPane`).
    public var focusIndicator: FocusIndicator = .both
    public var inactiveTabStyle: InactiveTabStyle = .fade
    public var inactiveTabStrength: CGFloat = 0.35
    /// Fraction of a pane's extent that counts as an edge drop zone.
    public var dropEdgeFraction: CGFloat = 0.28
    /// Clamp for the edge drop band.
    public var dropEdgeRange: ClosedRange<CGFloat> = 28...180
    /// Width of the "new column" drop zone centered on each column gap.
    public var newColumnDropWidth: CGFloat = 36
    /// Which docks own the frame's corners (cmux.json `layout.frameOrientation`).
    public var frameOrientation: FrameOrientation = .columnMajor
    /// DEV layout model prototype (Debug Settings `layout.prototype.*`); off draws the real layout.
    public var prototype = LayoutPrototypeSettings()

    public init() {}

    /// Smallest frame a pane gets while its screen has room: the minimum
    /// content area plus the chrome above it and the padding around both.
    public var minimumPaneSize: CGSize {
        CGSize(width: minimumPaneContentSize.width + panePadding * 2,
               height: paneChromeHeight + minimumPaneContentSize.height + panePadding * 2)
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
        style.panePadding = Metrics.panePadding
        style.paneCornerRadius = Metrics.paneCornerRadius
        style.showsPaneBorder = Metrics.paneBorder == .subtle
        style.drawsLines = Borders.drawsLines
        style.focusRing = DesignSettings.shared.focusRing
        style.focusIndicator = DesignSettings.shared.effectiveFocusIndicator
        style.inactiveTabStyle = FocusIndicatorTunables.inactiveTabStyle.value
        style.inactiveTabStrength = FocusIndicatorTunables.inactiveTabStrength.value
        style.attention = DesignSettings.shared.attention
        if !style.drawsLines {
            // No outlines: the focused pane is marked by the others' dim
            // (`inactivePaneDimming`), the unread mark by the sidebar badge.
            style.focusRing.enabled = false
            style.attention.width = 0
        }
        style.paneBorderColor = DesignSettings.shared.paneChrome.borderColor
        style.paneBorderWidth = Metrics.paneBorderWidth
        // cmux.json `layout.minimumPaneWidth` / `layout.minimumPaneHeight`.
        style.minimumPaneContentSize = DesignSettings.shared.minimumPaneContentSize
        style.frameOrientation = DesignSettings.shared.frameOrientation
        // Debug Settings overrides only (no override keeps the base style's
        // value; the tunables' defaults equal the literals above).
        if let value = LayoutTunables.inactivePaneDimming.override { style.inactivePaneDimming = value }
        if let value = LayoutTunables.focusRingAlpha.override { style.focusRingAlphaOverride = value }
        if let value = LayoutTunables.dropEdgeFraction.override { style.dropEdgeFraction = value }
        let edgeMinimum = LayoutTunables.dropEdgeMinimum.override, edgeMaximum = LayoutTunables.dropEdgeMaximum.override
        if edgeMinimum != nil || edgeMaximum != nil {
            let lower = edgeMinimum ?? style.dropEdgeRange.lowerBound
            style.dropEdgeRange = lower...max(lower, edgeMaximum ?? style.dropEdgeRange.upperBound)
        }
        if let value = LayoutTunables.newColumnDropWidth.override { style.newColumnDropWidth = value }
        if let width = LayoutTunables.minimumContentWidth.override { style.minimumPaneContentSize.width = width }
        if let height = LayoutTunables.minimumContentHeight.override { style.minimumPaneContentSize.height = height }
        style.prototype = LayoutPrototypeSettings(model: LayoutTunables.prototypeModel.value, dockEdge: LayoutTunables.prototypeDockEdge.value,
                                                  orientation: LayoutTunables.prototypeOrientation.value,
                                                  dockMode: LayoutTunables.prototypeDockMode.value.stickyMode)
        return style
    }
}
