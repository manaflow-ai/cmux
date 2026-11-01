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
            // Leo 2026-10-21 / Lawrence u8646: the menu is for the clicked row, or the whole selection when the
            // row is part of it; the selection and the shown workspace stay as they are (one rule with the ⋮ button).
            // A group's one row (`standsForGroup`) adds the group's menu (`SidebarRowMenu.menu(for:)`).
            return SidebarRowMenu(list: self).menu(for: id)
        case let .group(id)?, let .emptyGroup(id)?:
            // A right-click on a group (or its empty row) shows its one flat menu at once, as Finder and Safari
            // do (Lawrence 2026-10-20: no second step through the editor's More row). A
            // click on the name or the more button still opens the editor (cx-rcby).
            // A remote group (`SidebarSection.wrappedAsHostGroup`) shows its machine's menu.
            target = SidebarGroup.hostMachine(id).map { .section(.machine($0)) } ?? .group(id)
        case let .section(id)?, let .emptySection(id)?, let .folder(id, _)?:
            target = .section(id)
        case let .doneFold(fold)? where fold.kind == .archive:
            target = .background // the Archive row belongs to no list
        case let .doneFold(fold)?, let .showMore(fold)?:
            target = fold.group.map(SidebarContextTarget.group) ?? .section(fold.section)
        case let .item(item)?:
            target = .layoutItem(LayoutItemID(item))
        case .block?, .status?:
            target = .background
        case nil:
            target = .background
        }
        return contextMenuProvider(target)
    }
}
