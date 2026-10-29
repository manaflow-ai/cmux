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
    /// Gap between columns and at the outer horizontal edges in columns mode. Token:
    /// `Metrics.stripColumnGap` (0 by default for edge-to-edge separations).
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
    /// Smallest content width of a docked agent chat column (``DockRole/agentChat``): the Home
    /// list at its avatar-only minimum (76 pt), its divider and a transcript of about 30
    /// characters (280 pt, `HomeSidebarWidth.transcriptMinimum`). The generic pane minimum let
    /// that column shrink to 216 pt and its bubbles wrap one word per line (dogfood 2026-10-19).
    public var minimumAgentChatContentWidth: CGFloat = 360
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
    /// Floating panes (`Metrics.floatingPanes`): each pane's whole padded
    /// rect, tab strip included, is its rounded card, and split panes meet
    /// with no divider gap (`dividerThickness` 0).
    public var floatingPanes = false
    /// `layout.paneSeparation`: whether a divider draws at rest and whether
    /// it shows a line on hover or drag (none shows nothing).
    public var paneSeparation: PaneSeparation = .borders
    /// The focus ring (`focusRing.*`). Drawn in the overlay plane only.
    public var focusRing = FocusRingSettings()
    /// The attention ring of panes with an unread notification
    /// (`notifications.attention.*`).
    public var attention = AttentionSettings()
    /// Border color override (`layout.paneBorderColor`); nil is the theme's.
    public var paneBorderColor: ThemeRGB?
    /// Border width in points (`layout.paneBorderWidth`); nil is one device pixel.
    public var paneBorderWidth: CGFloat?
    /// Inactive pane dim amount when `LayoutModel.dimsInactivePanes` is on. Token: `Palette.inactivePaneDim`.
    public var inactivePaneDimming: CGFloat = 0.10
    /// The Ghostty config's unfocused-pane dim; when it dims, it replaces
    /// `inactivePaneDimming` on every unfocused pane.
    public var unfocusedPaneDim = UnfocusedPaneDim()
    /// Debug Settings `focus.ringAlpha`: the ring's foreground share in place
    /// of `focusRing.contrast`; nil follows the setting. Read here, in the
    /// observed style, so a slider move repaints the ring at once.
    public var focusRingAlphaOverride: CGFloat?
    /// `appearance.focusIndicator`, and how unfocused panes' tabs draw
    /// subtler when it marks tabs (`ChromeEmphasis.forPane`).
    public var focusIndicator: FocusIndicator = .tabs
    public var inactiveTabStyle: InactiveTabStyle = .fade
    public var inactiveTabStrength: CGFloat = 0.4
    /// Fraction of a pane's extent that counts as an edge drop zone
    /// (DESIGN.md (c)2: a quarter, half of the half a split gives).
    public var dropEdgeFraction: CGFloat = 0.25
    /// Floor and cap of the edge band (drop-zones DESIGN.md): 48 pt keeps an
    /// edge easy to hit on a small pane, and there is no cap, so the outer
    /// quarter of a big pane splits as in classic cmux (a 120 pt cap made the
    /// right quarter of a 1200 pt pane join it). `band(for:)` also keeps it
    /// at most a third of the extent, so a center always remains.
    public var dropEdgeRange: ClosedRange<CGFloat> = 48...CGFloat.greatestFiniteMagnitude
    /// How far past a zone line the pointer goes before the drop preview
    /// leaves the zone it shows (`DropZoneGeometry.zone`).
    public var dropZoneHysteresis: CGFloat = 12
    /// Width of the "new column" drop zone centered on each column gap.
    public var newColumnDropWidth: CGFloat = 36
    /// Height of the band at a screen's top and bottom edge that opens a
    /// dock (layout-model.md DD1).
    public var dockDropBand: CGFloat = 24
    /// The top dock band, below the tab bar: the tab strip takes drops 8 pt
    /// below its edge (TabDragSession providers, space4), so the top band is
    /// 8 pt deeper to leave the same 24 pt to hit as the other bands.
    public var dockTopDropBand: CGFloat = 32
    /// Which docks own the frame's corners (cmux.json `layout.frameOrientation`).
    public var frameOrientation: FrameOrientation = .columnMajor
    /// cmux.json `layout.rows` (plans/cmux-next/rows.md O1 to O3): off, a
    /// column's existing rows fit it like stacked panes and never scroll.
    public var rowsEnabled = true
    /// cmux.json `layout.scrollAreas` (plans/cmux-next/scroll-areas-DESIGN.md G1 to G5): on, a
    /// split tree that needs more width than its frame scrolls inside it instead of squashing
    /// its panes, and columns keep their width. Off (default) is today's layout.
    public var scrollAreasEnabled = false
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
        style.floatingPanes = Metrics.floatingPanes
        style.dividerThickness = style.floatingPanes ? 0 : Metrics.dividerThickness
        style.dividerHitThickness = Metrics.dividerHitWidth
        style.columnGap = Metrics.stripColumnGap
        style.panelCornerRadius = Metrics.panelCornerRadius
        style.paneChromeHeight = Metrics.tabStripHeight
        style.panePadding = Metrics.panePadding
        style.paneCornerRadius = Metrics.paneCornerRadius
        style.showsPaneBorder = Metrics.paneBorder == .subtle
        style.drawsLines = Borders.drawsLines
        style.paneSeparation = Metrics.paneSeparation
        style.focusRing = DesignSettings.shared.focusRing
        style.focusIndicator = DesignSettings.shared.effectiveFocusIndicator
        style.inactiveTabStyle = DesignSettings.shared.effectiveInactiveTabStyle
        style.inactiveTabStrength = FocusIndicatorTunables.inactiveTabStrength.value
        style.unfocusedPaneDim = DesignSettings.shared.unfocusedPaneDim
        style.inactivePaneDimming = Palette.inactivePaneDim
        style.attention = DesignSettings.shared.attention
        if !style.drawsLines {
            // No outlines: the focused pane is marked by the others' dim
            // (`inactivePaneDimming`), the unread mark by the sidebar badge.
            style.focusRing.enabled = false
            style.attention.width = 0
        }
        // Floating panes: no ring; the dim marks the focused pane (`inactiveDim`).
        if Metrics.floatingPanesHideFocusRing { style.focusRing.enabled = false }
        style.paneBorderColor = DesignSettings.shared.paneChrome.borderColor
        style.paneBorderWidth = Metrics.paneBorderWidth
        // cmux.json `layout.minimumPaneWidth` / `layout.minimumPaneHeight`.
        style.minimumPaneContentSize = DesignSettings.shared.minimumPaneContentSize
        style.frameOrientation = DesignSettings.shared.frameOrientation
        style.rowsEnabled = DesignSettings.shared.layoutRows
        style.scrollAreasEnabled = DesignSettings.shared.layoutScrollAreas
        // Debug Settings overrides only (no override keeps the base style's
        // value; the tunables' defaults equal the literals above).
        if let value = LayoutTunables.inactivePaneDimming.override { style.inactivePaneDimming = value }
        if let value = LayoutTunables.focusRingAlpha.override { style.focusRingAlphaOverride = value }
        if let value = LayoutTunables.dropEdgeFraction.override { style.dropEdgeFraction = value }
        let edgeMinimum = LayoutTunables.dropEdgeMinimum.override, edgeMaximum = LayoutTunables.dropEdgeMaximum.override
        if edgeMinimum != nil || edgeMaximum != nil {
            let lower = edgeMinimum ?? style.dropEdgeRange.lowerBound
            // A maximum of 0 is "no maximum" (the classic default).
            let upper = edgeMaximum.map { $0 > 0 ? $0 : CGFloat.greatestFiniteMagnitude } ?? style.dropEdgeRange.upperBound
            style.dropEdgeRange = lower...max(lower, upper)
        }
        if let value = LayoutTunables.dropZoneHysteresis.override { style.dropZoneHysteresis = value }
        if let value = LayoutTunables.newColumnDropWidth.override { style.newColumnDropWidth = value }
        if let width = LayoutTunables.minimumContentWidth.override { style.minimumPaneContentSize.width = width }
        if let height = LayoutTunables.minimumContentHeight.override { style.minimumPaneContentSize.height = height }
        style.prototype = LayoutPrototypeSettings(model: LayoutTunables.prototypeModel.value, dockEdge: LayoutTunables.prototypeDockEdge.value,
                                                  orientation: LayoutTunables.prototypeOrientation.value,
                                                  dockMode: LayoutTunables.prototypeDockMode.value.dockMode)
        return style
    }
}
