extension SidebarModel {
    /// Filter after `SidebarDocProjection.arrange`, which inserts machine
    /// links and group members independently of the band's layout items.
    static func hidingItems(_ hidden: Set<LayoutItemRef>, in sections: [SidebarSection]) -> [SidebarSection] {
        guard !hidden.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case .item(let item):
                    return hidden.contains(item.ref) ? nil : node
                case .workspace:
                    return node
                case .group(var group):
                    group.items.removeAll { hidden.contains($0.item.ref) }
                    return .group(group)
                }
            }
            return section
        }
    }
}
