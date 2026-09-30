public import CoreGraphics

/// A rect where a layout control takes the mouse but draws nothing over
/// pane content: a split divider's or column edge's hit area, which is
/// wider than its line and reaches into the neighboring panes. Content
/// drawn above the window (Chromium pages) keeps drawing there; the App
/// puts a click-catching panel above the page instead and forwards the
/// mouse to this window (`LayoutRootView.dividerMouseAreas`).
public nonisolated struct LayoutMouseArea: Hashable, Sendable {
    /// Stable while the divider exists.
    public var id: String
    /// In the coordinates of the view that reports it.
    public var rect: CGRect
    /// The divider resizes side-by-side panes (column resize cursor);
    /// otherwise stacked panes (row resize cursor).
    public var resizesColumns: Bool

    public init(id: String, rect: CGRect, resizesColumns: Bool) {
        self.id = id
        self.rect = rect
        self.resizesColumns = resizesColumns
    }
}
