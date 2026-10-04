public import AppKit
public import CmuxNextDesign

/// What the active screen shows of docked columns and the strip scrollbar,
/// in window coordinates (`debug.dock`).
public struct DockLayoutReport: Sendable {
    public struct Column: Sendable {
        public var column: ColumnID
        public var dock: DockColumn
        public var frameInWindow: CGRect
        public var coverInWindow: CGRect
        public var panes: [PaneID]
        public var hasBackdrop: Bool
    }

    public var columns: [Column]
    public var stripMinX: CGFloat
    public var stripWidth: CGFloat
    public var uncoveredInWindow: CGRect
    public var offset: CGFloat
    public var maxOffset: CGFloat
    public var contentWidth: CGFloat
    public var scrollbarMode: StripScrollbarMode
    public var scrollbarShown: Bool
    public var thumbInWindow: CGRect?
    public var bandInWindow: CGRect?
    /// Panes in stacking order (bottom to top) on the active screen.
    public var paneOrder: [PaneID]
}

extension LayoutRootView {
    public var dockReport: DockLayoutReport? {
        guard let active = model.activeScreenID, let screen = screenViews[active], window != nil else { return nil }
        let geometry = screen.geometry
        func inWindow(_ rect: CGRect) -> CGRect { screen.convert(rect, to: nil) }
        let columns = geometry.dock.map { entry in
            DockLayoutReport.Column(
                column: entry.column, dock: entry.dock, frameInWindow: inWindow(entry.frame), coverInWindow: inWindow(entry.cover),
                panes: model.activeScreen?.layout.columns.first { $0.id == entry.column }?.root.panes ?? [],
                hasBackdrop: screen.backdrops[entry.column] != nil
            )
        }
        let bar = screen.scrollbarReport
        return DockLayoutReport(
            columns: columns, stripMinX: geometry.stripMinX, stripWidth: geometry.stripWidth,
            uncoveredInWindow: inWindow(screen.uncoveredRect), offset: screen.scroll.value, maxOffset: geometry.maxOffset,
            contentWidth: geometry.contentWidth, scrollbarMode: model.stripScrollbar, scrollbarShown: bar?.shown ?? false,
            thumbInWindow: bar?.thumb.map(inWindow), bandInWindow: bar.map { inWindow($0.band) },
            paneOrder: screen.subviews.compactMap { ($0 as? PaneHostView)?.pane }
        )
    }
}
