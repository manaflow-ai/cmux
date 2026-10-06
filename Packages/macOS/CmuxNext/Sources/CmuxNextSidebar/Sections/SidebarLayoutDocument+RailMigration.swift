import Foundation

// The window rail (Leo, 2026-10-03) moved the destinations out of the
// sidebar's sections and changed the default layout; R52 (Lawrence,
// 2026-10-03) removed the rail. A stored layout that still equals the
// rail's default moves back to the sections default; a layout the user
// changed in any way is theirs and never migrates. The sections default
// before R53 (an inline bottom line) moves to the grid bottom row too.
extension SidebarLayoutDocument {
    /// What an old exact default migrates to: the sections default of that
    /// time, which still held CodeRouter. A stored layout keeps its items;
    /// only new defaults leave CodeRouter out (FIRST-PARTY-APPS).
    public nonisolated static var migrationTarget: SidebarLayoutDocument {
        var target = defaults
        target.sections[0].items.append(LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter")))
        return target
    }

    /// The ops that move a layout equal to the rail default back to the
    /// sections default, or none. The revision does not matter. They are
    /// ordinary layout ops, so the owner applies and syncs them like any
    /// edit, and Settings keeps its item id as it returns to the bottom line.
    public nonisolated var sectionsMigrationOps: [SidebarLayoutOp] {
        let top = Self.topSectionID, bottom = Self.bottomSectionID
        // The bottom row as a grid: Settings over 7 of 8 columns, the
        // account over 1 (R53). Items are re-added to carry their span.
        let gridBottom: [SidebarLayoutOp] = [
            .sectionUpdate(bottom, SectionPatch(layout: .grid, columns: .set(8))),
            .itemRemove(LayoutItemID("itm_settings")),
            .itemRemove(LayoutItemID("itm_account")),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings), span: 7), section: bottom, index: 0),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false, span: 1),
                     section: bottom, index: 1),
        ]
        if sections == Self.inlineBottomDefaults.sections { return gridBottom }
        guard sections == Self.railDefaults.sections else { return [] }
        return [
            .itemRemove(LayoutItemID("itm_history")),
            .itemRemove(LayoutItemID("itm_notifications")),
            .itemRemove(LayoutItemID("itm_customize")),
            .sectionUpdate(top, SectionPatch(maxRows: .clear)),
        ] + gridBottom
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

    /// R53's bottom row (Settings with its label over 7 of 8 columns, the
    /// account over the last), only to recognize it.
    public nonisolated static let gridBottomSection = LayoutSection(
        id: bottomSectionID, region: .bottom, look: .builtIn,
        arrangement: SectionArrangement(layout: .grid, align: .fill, columns: 8), items: [
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings), span: 7),
            LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false, span: 1),
        ])

    /// The sections default before R53 (one inline bottom line with
    /// Settings leading and the account trailing), only to recognize it.
    public nonisolated static let inlineBottomDefaults = SidebarLayoutDocument(sections: [
        LayoutSection(id: topSectionID, region: .top, look: .builtIn,
                      items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home)),
                              LayoutItem(id: LayoutItemID("itm_app_store"), ref: .builtIn(.appStore)),
                              LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))]),
        LayoutSection(id: workspacesSectionID, region: .middle, look: .list, content: .workspaces),
        LayoutSection(id: bottomSectionID, region: .bottom, look: .builtIn,
                      arrangement: SectionArrangement(layout: .inline, align: .fill), items: [
                          LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
                          LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false),
                      ]),
    ])

    /// The window rail's default layout as it was stored (Leo, 2026-10-03,
    /// #17153), only to recognize it.
    public nonisolated static let railDefaults = SidebarLayoutDocument(sections: [
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

    /// The ops that turn built-in Home and App Store items into app items
    /// (R63/R64), or none.
    /// Each item keeps its id, place, label and span.
    public nonisolated var appRefMigrationOps: [SidebarLayoutOp] {
        var ops: [SidebarLayoutOp] = []
        for section in sections {
            for (index, item) in section.items.enumerated() {
                guard let builtIn = item.ref.builtIn, let app = Self.firstPartyApps[builtIn] else { continue }
                ops.append(.itemRemove(item.id))
                ops.append(.itemAdd(LayoutItem(id: item.id, ref: .app(app), showsLabel: item.showsLabel, span: item.span),
                                    section: section.id, index: index))
            }
        }
        return ops
    }

    /// Home's item: the cmux/home app (R63/R64).
    public nonisolated static let homeRef = LayoutItemRef.app("cmux/home")

    /// Built-ins that are first-party apps now (R63/R64).
    public nonisolated static let firstPartyApps: [SidebarBuiltIn: String] = [.home: "cmux/home", .appStore: "cmux/app-store"]

    /// The large-tiles arrangement (#17349). It is no longer the default
    /// top (Lawrence 2026-10-05: rows); a user can still choose it.
    public nonisolated static let tilesArrangement = SectionArrangement(layout: .tiles, columns: 4)

    /// Every migration in order (sections, then app refs), as one op list
    /// that applies to this layout. No migration turns a plain-row top
    /// section into tiles; the tiles default was never stored (the store
    /// did not serve `sidebar-layout-v1` yet), so none moves back either.
    public nonisolated var layoutMigrationOps: [SidebarLayoutOp] {
        sectionsMigrationOps + sectionsMigration.appRefMigrationOps
    }

    /// This layout with `layoutMigrationOps` applied.
    public nonisolated var layoutMigration: SidebarLayoutDocument {
        var result = self
        for op in layoutMigrationOps {
            guard case .success(let next) = SidebarLayoutReducer.reduce(result, op) else { return self }
            result = next
        }
        return result
    }
}
