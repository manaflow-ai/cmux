import AppKit
import CmuxNextDesign

/// The workspace row's more button (cx-a9h6, ChatGPT project style): the
/// same menu as a right-click on the row, under the button on its trailing edge. Neither
/// selects nor shows the row (Lawrence 2026-10-21, u8646: "clicking 3 dots here should not
/// focus workspace"): the menu acts on the row, or on the whole selection when the row is in
/// it, as Finder's does. A helper beside SidebarListView (the list type is past its size limit).
@MainActor
struct SidebarRowMenu {
    let list: SidebarListView

    func show(for id: WorkspaceID) {
        guard let provider = list.contextMenuProvider, let view = list.rowViews[.workspace(id)] as? WorkspaceRowView,
              let menu = provider(target(for: id)) else { return }
        list.menuPresenter(menu, PopupAnchor(rect: view.moreButton.frame, edge: .trailing), view)
    }

    /// What a menu opened on row `id` acts on: the selection when the row is in it, else the row
    /// alone. The one rule for the more button and a right-click; it changes no selection.
    func target(for id: WorkspaceID) -> SidebarContextTarget {
        let selection = list.model.orderedSelection
        return .workspaces(list.model.selection.contains(id) && !selection.isEmpty ? selection : [id])
    }
}
