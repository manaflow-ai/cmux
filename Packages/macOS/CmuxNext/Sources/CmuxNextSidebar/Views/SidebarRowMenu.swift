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
        guard let view = list.rowViews[.workspace(id)] as? WorkspaceRowView, let menu = menu(for: id) else { return }
        // popUp tracks the menu modally and returns when it closes: the row's controls and its lit more button hold
        // for exactly that long, though the pointer leaves the row for the menu (Leo 2026-10-26).
        view.showsMenu = true
        defer { view.showsMenu = false }
        list.menuPresenter(menu, PopupAnchor(rect: view.moreButton.frame, edge: .trailing), view)
    }

    /// The menu for row `id`, from the App's provider. A row that is its group's one row (`standsForGroup`, no header
    /// drawn) adds the group's own menu under "Group options", so renaming, coloring or ungrouping stays reachable.
    func menu(for id: WorkspaceID) -> NSMenu? {
        guard let provider = list.contextMenuProvider else { return nil }
        let target = target(for: id)
        guard let menu = provider(target) else { return nil }
        guard target == .workspaces([id]), let row = list.displayed.row(for: .workspace(id)), row.standsForGroup,
              let group = row.group, let groupMenu = provider(.group(group)) else { return menu }
        let item = NSMenuItem(title: GroupEditorStrings.more, action: nil, keyEquivalent: "")
        item.submenu = groupMenu
        menu.addItem(.separator())
        menu.addItem(item)
        return menu
    }

    /// What a menu opened on row `id` acts on: the selection when the row is in it, else the row
    /// alone. The one rule for the more button and a right-click; it changes no selection.
    func target(for id: WorkspaceID) -> SidebarContextTarget {
        let selection = list.model.orderedSelection
        return .workspaces(list.model.selection.contains(id) && !selection.isEmpty ? selection : [id])
    }
}
