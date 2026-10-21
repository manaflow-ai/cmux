import AppKit
// Right-click: resolve the target, let the App build the menu from the
// action registry.
extension SidebarListViewComponents {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let contextMenuProvider else { return nil }
        let hit = clickHit(at: point)
        let target: SidebarContextTarget
        switch hit?.key {
        case let .workspace(id)?:
            if !model.selection.contains(id) {
                model.click(id)
                reload(animated: true)
            }
            target = .workspaces(model.orderedSelection.isEmpty ? [id] : model.orderedSelection)
        case let .group(id)?:
            // A right-click on a group shows its one flat menu at once, as Finder and Safari
            // do (Lawrence 2026-10-20: no second step through the editor's More row). A
            // click on the name or the more button still opens the editor (cx-rcby).
            target = .group(id)
        case let .section(id)?, let .emptySection(id)?, let .folder(id, _)?:
            target = .section(id)
        case let .tab(workspace, tab)?:
            target = .tab(workspace, tab)
        case let .item(item)?:
            target = .layoutItem(LayoutItemID(item))
        case .block?:
            target = .background
        case nil:
            target = .background
        }
        return contextMenuProvider(target)
    }
}
