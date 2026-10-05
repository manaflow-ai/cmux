import Foundation

/// Next / previous item inside one sidebar section (R119, Cmd-Ctrl-] and
/// Cmd-Ctrl-[): the section that holds the current item, wrapping at its
/// ends, skipping items `skip` names (hidden, unresolved). The workspaces
/// section and app sections hold no items; their caller steps workspaces.
public nonisolated enum SidebarSectionStepping {
    /// The item `offset` steps from `current` in its section, or nil when
    /// `current` is in no section or its section has no other item to reach.
    public static func step(from current: LayoutItemID, by offset: Int, in document: SidebarLayoutDocument,
                            skip: (LayoutItem) -> Bool) -> LayoutItemID? {
        guard offset != 0, let (s, _) = document.locate(current) else { return nil }
        let reachable = document.sections[s].items.filter { $0.id == current || !skip($0) }
        guard reachable.count > 1, let index = reachable.firstIndex(where: { $0.id == current }) else { return nil }
        let count = reachable.count
        return reachable[((index + offset) % count + count) % count].id
    }
}
