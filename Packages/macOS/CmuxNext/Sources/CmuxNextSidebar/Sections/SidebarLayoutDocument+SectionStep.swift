import Foundation

extension SidebarLayoutDocument {
    /// Next / previous item inside one sidebar section (R119, Cmd-Ctrl-] and
    /// Cmd-Ctrl-[): the item `offset` steps from `current` in the section that
    /// holds it, wrapping at its ends, skipping items `skip` names (hidden,
    /// unresolved). Nil when `current` is in no section or its section has no
    /// other item to reach. The workspaces section and app sections hold no
    /// items; their caller steps workspaces.
    public func sectionStep(from current: LayoutItemID, by offset: Int, skip: (LayoutItem) -> Bool) -> LayoutItemID? {
        guard offset != 0, let (s, _) = locate(current) else { return nil }
        let reachable = sections[s].items.filter { $0.id == current || !skip($0) }
        guard reachable.count > 1, let index = reachable.firstIndex(where: { $0.id == current }) else { return nil }
        let count = reachable.count
        return reachable[((index + offset) % count + count) % count].id
    }
}
