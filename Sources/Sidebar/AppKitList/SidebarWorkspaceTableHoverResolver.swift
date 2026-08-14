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

    @MainActor
    func newOptionHoveredRow(
        _ row: Int?,
        previousRowId: SidebarWorkspaceRenderItemID?,
        rows: [SidebarWorkspaceTableRowConfiguration],
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        guard modifiers.contains(.option), let row, rows.indices.contains(row),
              !rows[row].isGroupHeader,
              rows[row].id != previousRowId else { return nil }
        return row
    }
}
