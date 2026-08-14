import CmuxSettings

extension SidebarWorkspaceTableController {
    func setChromePalette(_ palette: ChromePalette) {
        guard chromePalette != palette else { return }
        chromePalette = palette
        containerView?.emptyDropIndicatorView.setChromePalette(palette)
        guard let table = containerView?.tableView else { return }
        let visibleRows = table.rows(in: table.visibleRect)
        for row in visibleRows.lowerBound..<(visibleRows.lowerBound + visibleRows.length)
        where rows.indices.contains(row) {
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarWorkspaceRowTableCellView:
                cell.setChromePalette(palette)
            case let cell as SidebarGroupHeaderTableCellView:
                cell.setChromePalette(palette)
            default:
                break
            }
        }
    }
}
