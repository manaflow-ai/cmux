import CoreGraphics

extension CGRect {
    /// This rect with its sides kept within `bounds`'s, its y and height as they are. A band row runs past the
    /// sidebar's edge by the row trim (`SidebarStyle.rowEdgeGap`); a card or outline made from it stops at the edge,
    /// and a slot past the content's end (an appended row) keeps its height (Codex review).
    func clippedX(to bounds: CGRect) -> CGRect {
        let minX = Swift.max(self.minX, bounds.minX), maxX = Swift.min(self.maxX, bounds.maxX)
        return CGRect(x: minX, y: minY, width: Swift.max(0, maxX - minX), height: height)
    }
}
