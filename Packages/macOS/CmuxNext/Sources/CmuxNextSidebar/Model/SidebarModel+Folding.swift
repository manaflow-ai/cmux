extension SidebarModel {
    /// Prepare group destinations when sections arrive, so the first fold does no lookup-building work before
    /// `onGroupFolded` starts the row motion. Keep the first occurrence, as `SidebarEdits.locateGroup` does.
    static func groupPaths(in sections: [SidebarSection]) -> [GroupID: (section: Int, node: Int)] {
        var paths: [GroupID: (section: Int, node: Int)] = [:]
        for (s, section) in sections.enumerated() {
            for (n, node) in section.nodes.enumerated() {
                if case let .group(group) = node, paths[group.id] == nil { paths[group.id] = (s, n) }
            }
        }
        return paths
    }

    /// `sections` with this window's `collapsed` sections folded and every other one open. A fold applies
    /// it to the shown list as it is: arranging an arranged list again lists the document's sections above
    /// the machine lists twice, and the list drops by their height (#23638's folded Chief group).
    static func folding(_ sections: [SidebarSection], _ collapsed: Set<SectionID>) -> [SidebarSection] {
        var sections = sections
        for index in sections.indices where sections[index].isCollapsed != collapsed.contains(sections[index].id) {
            sections[index].isCollapsed.toggle()
        }
        return sections
    }
}
