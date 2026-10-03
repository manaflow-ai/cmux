import Foundation

// Moving the destinations into the rail (Leo, 2026-10-03,
// plans/cmux-next/sidebar-sections.md 11) changed the default layout. A
// stored layout that still equals the old default moves to the new one; a
// layout the user changed in any way is theirs and never migrates.
extension SidebarLayoutDocument {
    /// The ops that turn this layout into the current defaults, or none.
    /// Only a layout whose sections equal `preRailDefaults` migrates (the
    /// revision does not matter: a layout edited and edited back is still
    /// the old default). The ops are ordinary layout ops, so the owner
    /// applies and syncs them like any edit, and Settings keeps its item id
    /// as it moves from the bottom line to the top section.
    public nonisolated var railMigrationOps: [SidebarLayoutOp] {
        guard sections == Self.preRailDefaults.sections else { return [] }
        let top = Self.topSectionID
        return [
            .itemAdd(LayoutItem(id: LayoutItemID("itm_history"), ref: .builtIn(.history)), section: top, index: 2),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_notifications"), ref: .builtIn(.notifications)), section: top, index: 3),
            .itemMove(LayoutItemID("itm_settings"), section: top, index: 4),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_customize"), ref: .builtIn(.customize)), section: top, index: 5),
            .sectionUpdate(top, SectionPatch(maxRows: .set(Self.railTopRows))),
        ]
    }

    /// This layout with `railMigrationOps` applied by the reducer; the
    /// layout itself when nothing migrates.
    public nonisolated var migratedToRail: SidebarLayoutDocument {
        var result = self
        for op in railMigrationOps {
            guard case .success(let next) = SidebarLayoutReducer.reduce(result, op) else { return self }
            result = next
        }
        return result
    }
}
