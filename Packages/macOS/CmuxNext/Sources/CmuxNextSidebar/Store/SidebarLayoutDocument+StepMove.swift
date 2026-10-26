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
}
