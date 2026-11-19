import AppKit
import CmuxNextDesign

/// The row restyle's one "+ New workspace" row (`SidebarNewWorkspaceRowView`, taste build 7): while
/// `experiments.sidebarRowStyle` is not off it sits at the top of the workspace list and the titlebar's + and its
/// chooser chevron hide (`layout()`), so the sidebar offers one New Workspace control. Off, nothing here runs past
/// one Bool read and the sidebar lays out as before.
extension SidebarViewComponents {
    /// Whether the "+ New workspace" row shows: the row restyle is on in the settings this sidebar draws from.
    var showsNewWorkspaceRow: Bool { design.sidebarRowStyle.isOn }

    /// The view a tab dropped on it becomes a new workspace from: the row while it shows, else the titlebar's +.
    var newWorkspaceDropTarget: NSView {
        if showsNewWorkspaceRow, let row = newWorkspaceRowView { return row }
        return newButton
    }

    /// Places the row at the top of `listFrame` (the list's frame from the bands) and returns the list's frame under
    /// it: one list row's height at the list's top padding and horizontal inset, the list one row step lower, so the
    /// first section or group sits where a second row would. Off it hides the row (if one was made) and returns
    /// `listFrame` unchanged.
    func layoutNewWorkspaceRow(in listFrame: NSRect) -> NSRect {
        guard showsNewWorkspaceRow else {
            if let row = newWorkspaceRowView { SidebarHiddenState.apply(true, to: row) }
            return listFrame
        }
        let row = newWorkspaceRowView ?? makeNewWorkspaceRow()
        SidebarHiddenState.apply(false, to: row)
        // The list's own metrics, read on every layout as its rows read them, so a density change moves both together.
        let metrics = list.metrics
        let step = min(metrics.rowHeight + metrics.rowSpacing, listFrame.height)
        let inset = list.inset
        row.frame = NSRect(x: listFrame.minX + inset, y: listFrame.minY + metrics.topPadding,
                           width: max(0, listFrame.width - inset * 2 - SidebarStyle.rowTrailingTrim),
                           height: min(metrics.rowHeight, max(0, listFrame.height - metrics.topPadding)))
        return NSRect(x: listFrame.minX, y: listFrame.minY + step, width: listFrame.width, height: listFrame.height - step)
    }

    /// Makes the row the first time it shows: the +'s action and menu, over the list's top fade.
    private func makeNewWorkspaceRow() -> SidebarNewWorkspaceRowView {
        let row = SidebarNewWorkspaceRowView()
        row.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        row.menuProvider = { [weak self] in self?.list.contextMenuProvider?(.background) }
        addSubview(row, positioned: .above, relativeTo: edgeFade)
        newWorkspaceRowView = row
        return row
    }
}
