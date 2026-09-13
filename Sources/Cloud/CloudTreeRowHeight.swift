import AppKit
import CmuxFoundation

@MainActor
struct CloudTreeRowHeight {
    let style: CloudTreeStyle
    let showsVPNWarning: Bool

    func height(of item: Any, in outline: NSOutlineView) -> CGFloat {
        guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
        if showsVPNWarning && node.isPortsGroup { return max(24, GlobalFontMagnification.scaledSize(style.rowHeight)) }
        if showsVPNWarning && node.isPortsEmptyPlaceholder {
            // AppKit reserves one disclosure slot per level, including the root.
            let indentation = CGFloat(max(0, outline.level(forItem: node)) + 1) * outline.indentationPerLevel
            let width = (outline.tableColumns.first?.width ?? outline.bounds.width)
                - indentation - CloudTreeRowGrid.disclosureGap - CloudTreeRowGrid.trailingPadding
            return CloudPortsVPNEmptyStateContent.height(width: width, style: style)
        }
        switch node.kind {
        case .machine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: true))
        case .localMachine, .pendingMachine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        default:
            return GlobalFontMagnification.scaledSize(style.rowHeight)
        }
    }
}
