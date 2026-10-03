import Testing
@testable import CmuxNextSidebar

/// Moving the destinations into the rail (Leo, 2026-10-03) and then taking
/// Home out of it change the default layout. A stored layout that still
/// equals a layout the app shipped before is rewritten to the current one
/// through ordinary layout ops (the owner applies them like any edit); a
/// layout the user changed is left exactly as it is.
@Suite struct SidebarLayoutMigrationTests {
    private let preRail = SidebarLayoutDocument.preRailDefaults
    private let railV1 = SidebarLayoutDocument.railV1Defaults

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

    /// The first rail layout: Home and the App Store led the rail.
    @Test func theRailV1DefaultsLedWithHome() {
        #expect(railV1.sections(in: .top, room: nil).flatMap(\.items).map(\.ref) == [
            .builtIn(.home), .builtIn(.appStore), .builtIn(.history), .builtIn(.notifications),
            .builtIn(.settings), .builtIn(.customize), .app("cmux/coderouter"),
        ])
        #expect(railV1.sections != SidebarLayoutDocument.defaults.sections)
    }

    @Test func aStoredRailV1LayoutBecomesTheNewDefaults() throws {
        let stored = SidebarLayoutDocument(revision: 3, sections: railV1.sections)
        let ops = stored.railMigrationOps
        #expect(ops.count == 4)
        let migrated = try apply(ops, to: stored)
        #expect(migrated.sections == SidebarLayoutDocument.defaults.sections)
        #expect(stored.migratedToRail.sections == SidebarLayoutDocument.defaults.sections)
        #expect(migrated.revision > stored.revision)
        #expect(migrated.firstItem(with: .builtIn(.home)) == nil)
        // The App Store keeps its item id as it moves under More.
        #expect(migrated.item(LayoutItemID("itm_app_store"))?.ref == .builtIn(.appStore))
    }

    @Test func aStoredPreRailLayoutChainsToTheNewDefaults() throws {
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

    /// Only the exact old defaults migrate: removing Home, adding an item,
    /// reordering or relabeling all count as the user's own layout.
    @Test(arguments: [SidebarLayoutDocument.preRailDefaults, SidebarLayoutDocument.railV1Defaults])
    func aCustomizedLayoutIsLeftAlone(old: SidebarLayoutDocument) throws {
        let edits: [SidebarLayoutOp] = [
            .itemRemove(LayoutItemID("itm_home")),
            .itemAdd(LayoutItem(id: LayoutItemID("itm_ws"), ref: .workspace("local:ws_1")), section: SidebarLayoutDocument.topSectionID, index: 9),
            .itemMove(LayoutItemID("itm_app_store"), section: SidebarLayoutDocument.topSectionID, index: 0),
            .itemUpdate(LayoutItemID("itm_account"), showsLabel: true),
            .sectionUpdate(SidebarLayoutDocument.bottomSectionID, SectionPatch(title: .set("Me"))),
        ]
        for edit in edits {
            let customized = try SidebarLayoutReducer.reduce(old, edit).get()
            #expect(customized.railMigrationOps.isEmpty, "\(edit)")
            #expect(customized.migratedToRail == customized, "\(edit)")
        }
    }

    /// The new defaults (and anything else) need nothing, so migrating
    /// twice is the same as once.
    @Test func theNewDefaultsNeedNoMigration() {
        #expect(SidebarLayoutDocument.defaults.railMigrationOps.isEmpty)
        for old in [preRail, railV1] {
            let once = old.migratedToRail
            #expect(once.railMigrationOps.isEmpty)
            #expect(once.migratedToRail == once)
        }
    }
}
