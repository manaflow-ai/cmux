import Foundation

extension SidebarLayoutDocument {
    /// Where `placement` puts item `item` among the items of the section that lists it (a
    /// tile or top row of Pinned, which has no row in the workspace list). The one plan
    /// behind Move Workspace Up, Down, to Top, to Bottom, Above and Below for such an item,
    /// for the sidebar document (doc item ids) and the layout document (layout item ids) alike.
    ///
    /// Move to Top keeps a leading Home item first: the pinned block's top is just under Home.
    ///
    /// - Parameters:
    ///   - item: The id of the moving item in this document.
    ///   - placement: Where it goes; an anchor names another item of this document.
    /// - Returns: The move, ``SidebarBandMove/stays`` when the item is already there, or nil
    ///   when no section lists `item`, or an anchor is not in its section.
    public func bandMove(_ item: String, _ placement: SidebarBandPlacement) -> SidebarBandMove? {
        guard let section = sections.first(where: { $0.items.contains { $0.id.rawValue == item } }),
              let at = section.items.firstIndex(where: { $0.id.rawValue == item }) else { return nil }
        let rest = section.items.filter { $0.id.rawValue != item }
        let ids = rest.map(\.id.rawValue)
        let index: Int
        switch placement {
        case .step(let offset):
            index = at + offset
            guard (0...ids.count).contains(index) else { return .stays }
        case .top:
            index = rest.prefix { $0.ref == Self.homeRef }.count
        case .bottom:
            index = ids.count
        case .above(let anchor):
            guard let found = ids.firstIndex(of: anchor) else { return nil }
            index = found
        case .below(let anchor):
            guard let found = ids.firstIndex(of: anchor) else { return nil }
            index = found + 1
        }
        guard index != at else { return .stays }
        let target = index < ids.count
            ? SidebarDocTarget(section: section.id.rawValue, before: ids[index])
            : SidebarDocTarget(section: section.id.rawValue, after: ids[index - 1])
        return .move(section: section.id, index: index, target: target)
    }
}
