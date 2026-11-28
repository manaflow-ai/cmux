import AppKit
import CmuxNextDesign

/// The workspace row's more button (cx-a9h6, ChatGPT project style): the
/// same menu as a right-click on the row, under the button. The row joins
/// the selection first, as a right-click does. A namespace beside
/// SidebarListView (the list type is past its size limit).
@MainActor
struct SidebarRowMenu {
    let list: SidebarListView

    func show(for id: WorkspaceID) {
        guard let provider = list.contextMenuProvider, let view = list.rowViews[.workspace(id)] as? WorkspaceRowView else { return }
        if !list.model.selection.contains(id) {
            list.model.click(id)
            list.reload(animated: true)
        }
        let selection = list.model.orderedSelection
        guard let menu = provider(.workspaces(selection.isEmpty ? [id] : selection)) else { return }
        let button = view.moreButton.frame
        _ = menu.popUp(positioning: nil, at: NSPoint(x: button.minX, y: button.maxY + Metrics.space1), in: view)
    }
}
