import AppKit

/// Pure hovered-row resolution shared by the table controller and unit tests.
struct SidebarWorkspaceTableHoverResolver {
    func hoveredRow(
        windowPoint: NSPoint?,
        convertToTable: (NSPoint) -> NSPoint,
        rowAtPoint: (NSPoint) -> Int,
        rowCount: Int
    ) -> Int? {
        guard let windowPoint else { return nil }
        let row = rowAtPoint(convertToTable(windowPoint))
        guard row >= 0, row < rowCount else { return nil }
        return row
    }
}
