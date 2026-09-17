import AppKit
import CmuxCloudMachines
import CmuxFoundation

@MainActor
struct CloudTreeRowHeight {
    let style: CloudTreeStyle

    func height(of item: Any, in _: NSOutlineView) -> CGFloat {
        guard let node = item as? CloudTreeNode else { return GlobalFontMagnification.scaledSize(style.rowHeight) }
        switch node.kind {
        case .machine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(
                hasStats: true,
                hasUsage: style.machineRowLayout == .twoLine
            ))
        case .localMachine, .pendingMachine:
            return GlobalFontMagnification.scaledSize(style.machineRowHeight(hasStats: false))
        default:
            return GlobalFontMagnification.scaledSize(style.rowHeight)
        }
    }
}
