import AppKit
import CmuxCloudMachines
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
        case .machine(let machine, _):
            let hasUsageRow = style.machineRowLayout == .twoLine
            let base = GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: true, hasUsage: hasUsageRow))
            guard hasUsageRow else { return base }
            let indentation = CGFloat(max(0, outline.level(forItem: node)) + 1) * outline.indentationPerLevel
            // Mirror the cell's stable hover slot, row decoration, band, and icon insets.
            let width = (outline.tableColumns.first?.width ?? outline.bounds.width) - indentation
                - CloudTreeRowGrid.disclosureGap - CloudTreeRowGrid.dotSlot - CloudTreeRowGrid.dotGap
                - CloudTreeRowGrid.trailingPadding * 2 - CloudTreeRowGrid.trailingGap - 22
                - (node.isPinned ? 13 : 0) - (style.machineBand ? 4 : 0)
            let resource = CloudTreeMachineResourceView(metrics: CloudMachineResourcePresentation(machine: machine), style: style)
            let usage = CloudTreeMachineDetailView(
                line: CloudTreeMachineRowContent(machine: machine, style: style).usageSummary, style: style
            )
            let magnification = GlobalFontMagnification.storedPercent
            let lineHeight = GlobalFontMagnification.scaledSize(style.machineResourceHeight)
            let resourceOverflow = style.showsMachineStats ? resource.height(width: width, magnification: magnification) - lineHeight : 0
            return base + resourceOverflow + usage.height(width: width, magnification: magnification) - lineHeight
        case .localMachine, .pendingMachine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        default:
            return GlobalFontMagnification.scaledSize(style.rowHeight)
        }
    }
}
