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
        // Moves keep item ids: the account is the same item, at the bottom
        // (after Recents); Settings left with amendment 2 (it is in the profile menu).
        #expect(migrated.locate(LayoutItemID("itm_account"))?.section == 3)
        #expect(migrated.locate(LayoutItemID("itm_settings")) == nil)
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

    /// Lawrence 2026-10-05: plain rows are the default top again. A stored
    /// plain-row top section (with CodeRouter after it or not) stays rows;
    /// no migration turns it into the large tiles.
    @Test func aPlainRowTopSectionStaysRows() {
        let rows = [LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home")),
                    LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))]
        let coderouter = LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))
        for items in [rows, rows + [coderouter]] {
            var stored = SidebarLayoutDocument.defaults
            stored.revision = 3
            stored.sections[0] = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)
            #expect(stored.layoutMigrationOps.isEmpty)
            #expect(stored.layoutMigration.section(SidebarLayoutDocument.topSectionID)?.arrangement == .list)
        }
    }
}

/// The sections defaults before SIDEBAR-FOOTER-MINIMAL (one inline line,
/// then R53's grid row with the Settings label) move to the minimal footer
/// (the avatar, then the gear) through ordinary ops; a customized one is kept.
@Suite struct SidebarGridBottomMigrationTests {
    @Test func theInlineBottomDefaultBecomesTheMinimalFooter() {
        let stored = SidebarLayoutDocument(revision: 4, sections: SidebarLayoutDocument.inlineBottomDefaults.sections)
        #expect(stored.layoutMigration.sections == SidebarLayoutDocument.migrationTarget.sections)
        #expect(stored.layoutMigration.layoutMigrationOps.isEmpty)
    }

    @Test func aCustomizedInlineBottomIsKept() throws {
        let custom = try SidebarLayoutReducer.reduce(SidebarLayoutDocument.inlineBottomDefaults,
                                                     .itemRemove(LayoutItemID("itm_account"))).get()
        #expect(custom.sectionsMigrationOps.isEmpty)
    }

    /// R53's grid bottom row, stored untouched, becomes the minimal footer
    /// whatever the top holds; the item ids stay.
    @Test func theGridBottomRowBecomesTheMinimalFooter() throws {
        var stored = SidebarLayoutDocument.defaults
        stored.revision = 9
        stored.sections[3] = SidebarLayoutDocument.gridBottomSection
        stored.sections[0].items.append(LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter")))
        let migrated = stored.layoutMigration
        #expect(migrated.section(SidebarLayoutDocument.bottomSectionID) == SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        #expect(migrated.section(SidebarLayoutDocument.topSectionID) == stored.section(SidebarLayoutDocument.topSectionID), "the top is kept")
        #expect(migrated.revision > stored.revision)
        #expect(migrated.layoutMigrationOps.isEmpty, "once")
    }

    @Test func aCustomizedGridBottomIsKept() throws {
        var stored = SidebarLayoutDocument.defaults
        stored.sections[3] = SidebarLayoutDocument.gridBottomSection
        let custom = try SidebarLayoutReducer.reduce(stored, .itemUpdate(LayoutItemID("itm_account"), showsLabel: true)).get()
        #expect(custom.sectionsMigrationOps.isEmpty)
    }
}
