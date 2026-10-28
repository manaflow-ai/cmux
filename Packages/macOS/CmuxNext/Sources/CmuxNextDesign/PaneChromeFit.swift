public import CoreGraphics

/// What a pane's chrome shows at the pane's size (Lawrence 2026-10-28: "we should let panes be even smaller, idk
/// what use cases people might have, but we should support it"). The chrome gives way to the content, never the
/// other way round, and nothing overlaps:
///
/// - narrower than ``compactStripWidth``: the tab strip is compact (icon-only tabs, no +; the pane's "…" holds
///   what the + and the pinned buttons offered);
/// - shorter than the strip plus one cell row: the strip hides and the content has the whole pane;
/// - thinner than one cell (``drawableContent``) along either axis: the pane is folded, a bar that shows the
///   selected tab's icon when it fits and expands on a click or Ctrl-Cmd-X (`pane.expandCollapsed`). Its content
///   is hidden: a terminal keeps its grid and its process.
///
/// The layout's floors (`LayoutStyle.minimumPaneSize`) use the same numbers, so a pane the layout keeps at its
/// floor shows its content, and only a pane it folds shows the bar. Pure, so the rules are tested with fixed sizes.
public nonisolated struct PaneChromeFit: Equatable, Sendable {
    /// How much of the tab strip shows.
    public enum Strip: Equatable, Sendable {
        /// Tabs with titles, the + and the pinned buttons.
        case full
        /// Icon-only tabs and "…" only.
        case compact
        /// No strip: the pane is too short, folded, or its strip is hidden.
        case hidden
    }

    /// The smallest content a pane draws: one terminal cell at the default 13 pt font (8 x 16 pt).
    public static let drawableContent = CGSize(width: 8, height: 16)
    /// Below this width the strip is compact.
    public static let compactStripWidth: CGFloat = 160

    public var strip: Strip
    /// The pane is a folded bar: thinner than one cell along at least one axis.
    public var isCollapsed: Bool

    /// - Parameters:
    ///   - paneSize: The pane's content area (its cell less the padding).
    ///   - stripHeight: The strip's full height; 0 when the pane hides its strip.
    public init(paneSize: CGSize, stripHeight: CGFloat) {
        let cell = Self.drawableContent
        isCollapsed = paneSize.width < cell.width - 0.5 || paneSize.height < cell.height - 0.5
        if isCollapsed || stripHeight <= 0 || paneSize.height < stripHeight + cell.height - 0.5 {
            strip = .hidden
        } else {
            strip = paneSize.width < Self.compactStripWidth ? .compact : .full
        }
    }
}
