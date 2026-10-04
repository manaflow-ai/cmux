import Foundation

// The window rail (Leo, 2026-10-03) moved the destinations out of the
// sidebar's sections and changed the default layout; R52 (Lawrence,
// 2026-10-03) removed the rail. A stored layout that still equals the
// rail's default moves back to the sections default; a layout the user
// changed in any way is theirs and never migrates.
extension SidebarLayoutDocument {
    /// The ops that move a layout equal to the rail default back to the
    /// sections default, or none. The revision does not matter. They are
    /// ordinary layout ops, so the owner applies and syncs them like any
    /// edit, and Settings keeps its item id as it returns to the bottom line.
    public nonisolated var sectionsMigrationOps: [SidebarLayoutOp] {
        guard sections == Self.railDefaults.sections else { return [] }
        let top = Self.topSectionID
        return [
            .itemRemove(LayoutItemID("itm_history")),
            .itemRemove(LayoutItemID("itm_notifications")),
            .itemRemove(LayoutItemID("itm_customize")),
            .itemMove(LayoutItemID("itm_settings"), section: Self.bottomSectionID, index: 0),
            .sectionUpdate(top, SectionPatch(maxRows: .clear)),
        ]
    }

    /// This layout with `sectionsMigrationOps` applied by the reducer; the
    /// layout itself when nothing migrates.
    public nonisolated var sectionsMigration: SidebarLayoutDocument {
        var result = self
        for op in sectionsMigrationOps {
            guard case .success(let next) = SidebarLayoutReducer.reduce(result, op) else { return self }
            result = next
        }
        return result
    }

    /// The window rail's default layout as it was stored (Leo, 2026-10-03,
    /// #17153), only to recognize it.
    public static let railDefaults = SidebarLayoutDocument(sections: [
        LayoutSection(id: topSectionID, region: .top, look: .builtIn, maxRows: 4,
                      items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home)),
                              LayoutItem(id: LayoutItemID("itm_app_store"), ref: .builtIn(.appStore)),
                              LayoutItem(id: LayoutItemID("itm_history"), ref: .builtIn(.history)),
                              LayoutItem(id: LayoutItemID("itm_notifications"), ref: .builtIn(.notifications)),
                              LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
                              LayoutItem(id: LayoutItemID("itm_customize"), ref: .builtIn(.customize)),
                              LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))]),
        LayoutSection(id: workspacesSectionID, region: .middle, look: .list, content: .workspaces),
        LayoutSection(id: bottomSectionID, region: .bottom, look: .builtIn,
                      arrangement: SectionArrangement(layout: .inline, align: .fill), items: [
                          LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false),
                      ]),
    ])
}
