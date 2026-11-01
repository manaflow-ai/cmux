import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The Chief occupies the shared end column; every existing status stays in the next slot.
    /// Hover controls replace the avatar through the same column-mark path as dots and spinners.
    func layoutColumnMark(cy: CGFloat, rowWidth: CGFloat, markReplacesStatus: Bool) -> (view: NSView, trailing: CGFloat)? {
        guard !chiefMark.isHidden else {
            return layoutStatusColumnMark(cy: cy, rowWidth: rowWidth, markReplacesStatus: markReplacesStatus)
        }
        chiefMark.frame = SidebarStyle.trailingColumnFrame(rowWidth: rowWidth, centerY: cy, side: SidebarStyle.controlSize)
        let status = layoutStatusColumnMark(cy: cy, rowWidth: rowWidth - SidebarStyle.trailingSlotPitch,
                                           markReplacesStatus: markReplacesStatus)
        return (chiefMark, status?.trailing ?? SidebarStyle.trailingColumnStart(rowWidth: rowWidth) - Metrics.space1)
    }
}
