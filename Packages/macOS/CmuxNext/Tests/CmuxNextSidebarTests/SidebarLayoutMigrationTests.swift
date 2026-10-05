import Testing
@testable import CmuxNextSidebar

/// The window rail (Leo, 2026-10-03) changed the default layout; R52
/// (Lawrence, 2026-10-03) removed the rail. A stored layout that still
/// equals the rail's default is rewritten to the sections default through
/// ordinary layout ops (the owner applies them like any edit); a layout the
/// user changed is left exactly as it is.
@Suite struct SidebarLayoutMigrationTests {
    private let rail = SidebarLayoutDocument.railDefaults

    private func apply(_ ops: [SidebarLayoutOp], to document: SidebarLayoutDocument) throws -> SidebarLayoutDocument {
        try ops.reduce(document) { try SidebarLayoutReducer.reduce($0, $1).get() }
    }

    @Test func aStoredRailLayoutBecomesTheSectionsDefaults() throws {
        let stored = SidebarLayoutDocument(revision: 7, sections: rail.sections)
        let ops = stored.layoutMigrationOps
        #expect(!ops.isEmpty)
        let migrated = try apply(ops, to: stored)
        #expect(migrated.sections == SidebarLayoutDocument.migrationTarget.sections)
        #expect(stored.layoutMigration.sections == SidebarLayoutDocument.migrationTarget.sections)
        // Each op is a change the owner commits, so the revision moves on.
        #expect(migrated.revision > stored.revision)
        // Moves keep item ids: Settings is the same item, back at the bottom.
        #expect(migrated.locate(LayoutItemID("itm_settings"))?.section == 2)
    }

    /// Only the exact rail default migrates.
    @Test func aCustomizedLayoutIsLeftAlone() throws {
        let edits: [SidebarLayoutOp] = [
            .itemRemove(LayoutItemID("itm_home")),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_ws"), ref: .workspace("local:ws_1")), section: SidebarLayoutDocument.topSectionID, index: 9),
            .itemMove(LayoutItemID("itm_app_store"), section: SidebarLayoutDocument.topSectionID, index: 0),
            .itemUpdate(LayoutItemID("itm_account"), showsLabel: true),
            .sectionUpdate(SidebarLayoutDocument.bottomSectionID, SectionPatch(title: .set("Me"))),
        ]
        for edit in edits {
            let customized = try SidebarLayoutReducer.reduce(rail, edit).get()
            #expect(customized.sectionsMigrationOps.isEmpty, "\(edit)")
            #expect(customized.sectionsMigration == customized, "\(edit)")
        }
    }

    /// The sections defaults need nothing, so migrating twice is the same as once.
    @Test func theDefaultsNeedNoMigration() {
        #expect(SidebarLayoutDocument.defaults.layoutMigrationOps.isEmpty)
        let once = rail.layoutMigration
        #expect(once.layoutMigrationOps.isEmpty)
        #expect(once.layoutMigration == once)
    }
}

/// R53: the sections default before the grid bottom row (one inline line)
/// moves to the grid row through ordinary ops; a customized one is kept.
@Suite struct SidebarGridBottomMigrationTests {
    @Test func theInlineBottomDefaultBecomesTheGridRow() {
        let stored = SidebarLayoutDocument(revision: 4, sections: SidebarLayoutDocument.inlineBottomDefaults.sections)
        #expect(stored.layoutMigration.sections == SidebarLayoutDocument.migrationTarget.sections)
        #expect(stored.layoutMigration.layoutMigrationOps.isEmpty)
    }

    @Test func aCustomizedInlineBottomIsKept() throws {
        let custom = try SidebarLayoutReducer.reduce(SidebarLayoutDocument.inlineBottomDefaults,
                                                     .itemRemove(LayoutItemID("itm_account"))).get()
        #expect(custom.sectionsMigrationOps.isEmpty)
    }
}
