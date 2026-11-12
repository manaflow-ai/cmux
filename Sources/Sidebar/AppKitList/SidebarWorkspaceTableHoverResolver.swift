import AppKit

/// Pure hovered-row resolution shared by the table controller and unit tests.
struct SidebarWorkspaceTableHoverResolver {
    func hoveredRow(
        windowPoint: NSPoint?,
        convertToTable: (NSPoint) -> NSPoint,
        rowAtPoint: (NSPoint) -> Int,
        rowCount: Int,
        visibleRect: NSRect? = nil
    ) -> Int? {
        guard let windowPoint else { return nil }
        let tablePoint = convertToTable(windowPoint)
        // rowAtPoint matches on y alone, so a pointer beside the sidebar
        // (over the terminal) would otherwise hover the row at that height.
        if let visibleRect, !visibleRect.contains(tablePoint) { return nil }
        let row = rowAtPoint(tablePoint)
        guard row >= 0, row < rowCount else { return nil }
        return row
    }
}
