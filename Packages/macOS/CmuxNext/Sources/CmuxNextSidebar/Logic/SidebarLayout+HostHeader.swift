import Foundation

nonisolated extension SidebarLayout {
    /// A section header's height: one detail line taller for a remote group whose machine carries
    /// its room (`SidebarMachine.room`), drawn under the name. The sole machine's header titles the
    /// list ("Projects") and draws no room, so it keeps the one-line height (`SectionHeaderRowView`).
    static func headerHeight(_ section: SidebarSection, _ m: SidebarLayoutMetrics, titlesProjects: Bool) -> CGFloat {
        guard section.isHostGroup, section.machine?.room != nil, !titlesProjects else { return m.sectionHeaderHeight }
        return m.sectionHeaderHeight + (m.rowHeightWithSubtitle - m.rowHeight)
    }
}
