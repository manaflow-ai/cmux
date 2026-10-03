import Testing
@testable import CmuxNextSidebar

/// Moving the destinations into the rail (Leo, 2026-10-03) changes the
/// default layout. A stored layout that still equals the layout the app
/// shipped before is rewritten to the new one through ordinary layout ops
/// (the owner applies them like any edit); a layout the user changed is
/// left exactly as it is.
@Suite struct SidebarLayoutMigrationTests {
    private let preRail = SidebarLayoutDocument.preRailDefaults

    private func apply(_ ops: [SidebarLayoutOp], to document: SidebarLayoutDocument) throws -> SidebarLayoutDocument {
        try ops.reduce(document) { try SidebarLayoutReducer.reduce($0, $1).get() }
    }

    /// The layout before the rail: Home, the App Store and CodeRouter on top,
    /// Settings and the account on one line at the bottom.
    @Test func thePreRailDefaultsAreTheOldLayout() {
        #expect(preRail.sections(in: .top, room: nil).flatMap(\.items).map(\.ref) == [.builtIn(.home), .builtIn(.appStore), .app("cmux/coderouter")])
        #expect(preRail.sections(in: .bottom, room: nil).flatMap(\.items).map(\.ref) == [.builtIn(.settings), .builtIn(.account)])
        #expect(preRail.sections != SidebarLayoutDocument.defaults.sections)
    }

    @Test func aStoredPreRailLayoutBecomesTheNewDefaults() throws {
        let stored = SidebarLayoutDocument(revision: 7, sections: preRail.sections)
        let ops = stored.railMigrationOps
        #expect(!ops.isEmpty)
        let migrated = try apply(ops, to: stored)
        #expect(migrated.sections == SidebarLayoutDocument.defaults.sections)
        #expect(stored.migratedToRail.sections == SidebarLayoutDocument.defaults.sections)
        // Each op is a change the owner commits, so the revision moves on.
        #expect(migrated.revision > stored.revision)
        // Moves keep item ids: Settings is the same item, now on top.
        #expect(migrated.locate(LayoutItemID("itm_settings"))?.section == 0)
    }

    /// Only the exact old default migrates: removing Home, adding an item,
    /// reordering or relabeling all count as the user's own layout.
    @Test func aCustomizedLayoutIsLeftAlone() throws {
        let edits: [SidebarLayoutOp] = [
            .itemRemove(LayoutItemID("itm_home")),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_ws"), ref: .workspace("local:ws_1")), section: SidebarLayoutDocument.topSectionID, index: 9),
            .itemMove(LayoutItemID("itm_app_store"), section: SidebarLayoutDocument.topSectionID, index: 0),
            .itemUpdate(LayoutItemID("itm_account"), showsLabel: true),
            .sectionUpdate(SidebarLayoutDocument.bottomSectionID, SectionPatch(title: .set("Me"))),
        ]
        for edit in edits {
            let customized = try SidebarLayoutReducer.reduce(preRail, edit).get()
            #expect(customized.railMigrationOps.isEmpty, "\(edit)")
            #expect(customized.migratedToRail == customized, "\(edit)")
        }
    }

    /// The new defaults (and anything else) need nothing, so migrating
    /// twice is the same as once.
    @Test func theNewDefaultsNeedNoMigration() {
        #expect(SidebarLayoutDocument.defaults.railMigrationOps.isEmpty)
        let once = preRail.migratedToRail
        #expect(once.railMigrationOps.isEmpty)
        #expect(once.migratedToRail == once)
    }
}
