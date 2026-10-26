import Foundation

extension SidebarLayoutDocument {
    /// Where Move Up (-1) or Down (+1) puts document item `item` among the items of the band
    /// section that lists it (a tile or top row of Pinned, which has no list row): next to its
    /// neighbor there. Nil at either end, or when no band section lists it.
    public func stepMoveTarget(_ item: String, by offset: Int) -> SidebarDocTarget? {
        for section in sections {
            let ids = section.items.map(\.id.rawValue)
            guard let at = ids.firstIndex(of: item) else { continue }
            guard ids.indices.contains(at + offset) else { return nil }
            let anchor = ids[at + offset]
            return offset > 0 ? SidebarDocTarget(section: section.id.rawValue, after: anchor)
                : SidebarDocTarget(section: section.id.rawValue, before: anchor)
        }
        return nil
    }

    /// The same step on the layout document (pins as layout tiles, no sidebar document): the
    /// `item.move` op that puts `id` one place up or down in its section. Nil at either end.
    public func stepMoveOp(_ id: LayoutItemID, by offset: Int) -> SidebarLayoutOp? {
        guard let (s, i) = locate(id), sections[s].items.indices.contains(i + offset) else { return nil }
        // `item.move`'s index counts the section's items without the moved one.
        return .itemMove(id, section: sections[s].id, index: i + offset)
    }
}
