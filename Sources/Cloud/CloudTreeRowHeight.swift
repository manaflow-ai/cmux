import CmuxCloud
import AppKit
import CmuxCloudMachines
import CmuxFoundation

@MainActor
struct CloudTreeRowHeight {
    let style: CloudTreeStyle

    func height(of item: Any, in outlineView: NSOutlineView) -> CGFloat {
        guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
        switch node.kind {
        case .devicesEmpty(let section):
            return GlobalFontMagnification.scaledSize(CloudTreeDevicesEmptyView.rowHeight(for: section, style: style))
        case .machine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(
                hasStats: false,
                hasUsage: false
            ))
        // Devices sit on This Mac's single line: presence and counts are a dim
        // inline fact and a tooltip, never extra lines.
        case .localMachine, .pendingMachine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        case .device:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        case .placeholder(_, let placeholder) where placeholder.portStatus != nil:
            guard let presentation = placeholder.portStatus else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
            let level = outlineView.level(forItem: node)
            let width = CloudTreeLayoutMetrics().portsContentWidth(
                columnWidth: outlineView.tableColumns.first?.width ?? outlineView.bounds.width,
                level: level, style: style
            )
            return CloudPortsStatusContent.height(
                width: width,
                presentation: presentation,
                style: style
            )
        default:
            return GlobalFontMagnification.scaledSize(style.rowHeight)
        }
    }
}
