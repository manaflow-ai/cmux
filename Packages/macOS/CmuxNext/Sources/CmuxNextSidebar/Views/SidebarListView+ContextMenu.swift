import AppKit

// Right-click: resolve the target, let the App build the menu from the
// action registry.

extension SidebarListView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenuProvider else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let target: SidebarContextTarget
        switch displayed.row(at: point.y)?.key {
        case let .workspace(id)?:
            if !model.selection.contains(id) {
                model.click(id)
                reload(animated: true)
            }
            target = .workspaces(model.orderedSelection.isEmpty ? [id] : model.orderedSelection)
        case let .group(id)?:
            target = .group(id)
        case let .section(id)?, let .emptySection(id)?:
            target = .section(id)
        case let .tab(workspace, _)?:
            target = .workspaces([workspace])
        case nil:
            target = .background
        }
        return contextMenuProvider(target)
    }
}
