import AppKit
import CmuxCloudMachines
import CmuxFoundation

@MainActor
struct CloudTreeRowHeight {
    let style: CloudTreeStyle

    func height(of item: Any, in outlineView: NSOutlineView) -> CGFloat {
        guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
        switch node.kind {
        case .machine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(
                hasStats: false,
                hasUsage: false
            ))
        case .localMachine, .pendingMachine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        case .placeholder(_, let placeholder) where placeholder.portStatus != nil:
            guard let presentation = placeholder.portStatus else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
            let cellWidth = max(180, (outlineView.tableColumns.first?.width ?? outlineView.bounds.width) - style.rowGrid.trailingPadding - style.indentPerLevel * CGFloat(max(0, outlineView.level(forRow: outlineView.row(forItem: node)))))
            return CloudPortsStatusContent.height(
                width: max(180, cellWidth),
                presentation: presentation,
                style: style
            )
        default:
            return GlobalFontMagnification.scaledSize(style.rowHeight)
        }
    }
}
