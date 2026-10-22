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
            target = workspaceMenuTarget(id)
        case let .group(id)?:
            // A right-click on a group shows its one flat menu at once, as Finder and Safari
            // do (Lawrence 2026-10-20: no second step through the editor's More row). A
            // click on the name or the more button still opens the editor (cx-rcby).
            target = .group(id)
        case let .section(id)?, let .emptySection(id)?, let .folder(id, _)?:
            target = .section(id)
        case let .doneFold(fold)?, let .showMore(fold)?:
            target = fold.group.map(SidebarContextTarget.group) ?? .section(fold.section)
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

    /// A workspace row's menu (a right-click, or the row's more button, `SidebarRowMenu`). Leo 2026-10-21:
    /// "RIGHT CLICKING ... ON A WORKSPACE SHOULDN'T BE IMMEDIATELY FOCUSING". The menu is for the row, or for
    /// the whole selection when the row is part of it; the selection and the shown workspace stay as they are.
    func workspaceMenuTarget(_ id: WorkspaceID) -> SidebarContextTarget {
        let selection = model.orderedSelection
        return .workspaces(selection.contains(id) ? selection : [id])
    }
}
