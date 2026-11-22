import Testing
@testable import CmuxNextSidebar

/// R63/R64 (coordinator 2026-10-04): Home and the App Store are apps
/// (cmux/home, cmux/app-store) like CodeRouter, so their sidebar items are
/// app items. The defaults hold app refs, and a stored layout's built-in
/// Home and App Store items become app items through ordinary layout ops,
/// keeping their ids, places and labels. Migrating twice changes nothing.
@Suite struct AppRefMigrationTests {
    @Test func theDefaultsHoldTheFirstPartyAppsAsAppItems() {
        let top = SidebarLayoutDocument.defaults.sections(in: .top, room: nil).flatMap(\.items)
        #expect(top.map(\.ref) == [.app("cmux/home"), .app("cmux/app-store")])
        #expect(top.map(\.id.rawValue) == ["itm_home", "itm_app_store"])
    }

    @Test func builtInHomeAndAppStoreBecomeAppItemsInPlace() throws {
        // A customized layout: App Store first, Home moved to the bottom.
        var doc = SidebarLayoutDocument.inlineBottomDefaults
        doc.sections[0].items = [LayoutItem(id: LayoutItemID("itm_app_store"), ref: .builtIn(.appStore)),
                                 LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))]
        let bottom = doc.sections.firstIndex { $0.id == SidebarLayoutDocument.bottomSectionID }!
        doc.sections[bottom].items.insert(LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home), showsLabel: false), at: 1)
        let ops = doc.appRefMigrationOps
        #expect(!ops.isEmpty)
        let migrated = try ops.reduce(doc) { try SidebarLayoutReducer.reduce($0, $1).get() }
        #expect(migrated.sections[0].items.map(\.ref) == [.app("cmux/app-store"), .app("cmux/coderouter")])
        #expect(migrated.sections[bottom].items[1] == LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"), showsLabel: false))
        // Twice is once.
        #expect(migrated.appRefMigrationOps.isEmpty)
        #expect(SidebarLayoutDocument.defaults.appRefMigrationOps.isEmpty)
    }

    /// The service's one migration chain: the old exact defaults move to the
    /// current defaults (sections, grid bottom, app refs) in one pass.
    @Test func theOldDefaultsReachTheCurrentDefaults() {
        for old in [SidebarLayoutDocument.railDefaults, SidebarLayoutDocument.inlineBottomDefaults] {
            #expect(old.layoutMigration.sections == SidebarLayoutDocument.migrationTarget.sections)
            #expect(old.layoutMigration.layoutMigrationOps.isEmpty)
        }
    }
}
