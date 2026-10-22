import AppKit
import CmuxNextDesign

/// The workspace row's more button (cx-a9h6, ChatGPT project style): the
/// same menu as a right-click on the row, under the button on its trailing edge. Like a right-click
/// (`menu(for:)`), it selects nothing and switches to nothing: the menu is for the row, or for the
/// whole selection when the row is part of it. A namespace beside SidebarListView (the list type is
/// past its size limit).
@MainActor
struct SidebarRowMenu {
    let list: SidebarListView

    func show(for id: WorkspaceID) {
        guard let provider = list.contextMenuProvider, let view = list.rowViews[.workspace(id)] as? WorkspaceRowView else { return }
        guard let menu = provider(list.workspaceMenuTarget(id)) else { return }
        list.menuPresenter(menu, PopupAnchor(rect: view.moreButton.frame, edge: .trailing), view)
    }
}
