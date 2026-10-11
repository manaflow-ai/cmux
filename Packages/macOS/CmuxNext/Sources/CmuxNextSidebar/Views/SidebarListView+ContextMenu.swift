import AppKit
// Right-click: resolve the target, let the App build the menu from the
// action registry.
extension SidebarListView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if case let .group(id)? = displayed.row(at: point.y)?.key {
            // A right-click on a group shows its full menu, the same as its
            // more button (cx-a9h6); a click on the chip edits name and color.
            groupEditing.showMenu(id)
            return nil
        }
        guard let contextMenuProvider else { return nil }
        let target: SidebarContextTarget
        switch displayed.row(at: point.y)?.key {
        case let .workspace(id)?:
            if !model.selection.contains(id) {
                model.click(id)
                reload(animated: true)
            }
            target = .workspaces(model.orderedSelection.isEmpty ? [id] : model.orderedSelection)
        case .group?:
            return nil
        case let .section(id)?, let .emptySection(id)?, let .folder(id, _)?:
            target = .section(id)
        case let .tab(workspace, tab)?:
            target = .tab(workspace, tab)
        case nil:
            target = .background
        }
        return contextMenuProvider(target)
    }
}
