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
        /// The inner-edge resize handle (the dock's rim); nil when the
        /// column is not drawn as a dock.
        public var rimInWindow: CGRect?
        /// False when the layout holds the flag but the geometry draws the
        /// column in the strip (for example a screen of only docked columns).
        public var shownAsDock: Bool
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
        // Every column the layout docks, drawn as a dock or not, so a caller
        // never sees an empty list while a flag is set.
        let layoutColumns = model.activeScreen?.layout.columns ?? []
        let columns = layoutColumns.compactMap { column -> DockLayoutReport.Column? in
            guard let dock = column.dock else { return nil }
            let entry = geometry.dock.first { $0.column == column.id }
            let frame = entry?.frame ?? geometry.columns[column.id] ?? .zero
            let rim = entry == nil ? nil : geometry.columnEdges.first { $0.column == column.id && $0.dockEdge != nil }?.hitFrame
            return DockLayoutReport.Column(
                column: column.id, dock: entry?.dock ?? dock, frameInWindow: inWindow(frame),
                coverInWindow: entry.map { inWindow($0.cover) } ?? .zero, rimInWindow: rim.map(inWindow),
                shownAsDock: entry != nil, panes: column.root.panes, hasBackdrop: screen.backdrops[column.id] != nil
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
