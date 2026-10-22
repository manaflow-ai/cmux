extension SidebarModel {
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
