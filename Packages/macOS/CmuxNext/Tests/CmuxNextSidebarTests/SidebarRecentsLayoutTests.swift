import Testing
@testable import CmuxNextSidebar

/// Recents sits under the workspaces, as the ChatGPT desktop app lists
/// Recents under Projects. A stored layout equal to a default from before
/// Recents gains it through an ordinary op; a changed layout keeps its sections.
@Suite struct SidebarRecentsLayoutTests {
    private let recents = SidebarLayoutDocument.recentsSectionID

    /// The defaults before Recents: today's without the section.
    private func earlier(_ document: SidebarLayoutDocument) -> SidebarLayoutDocument {
        var earlier = document
        earlier.revision = 5
        earlier.sections.removeAll { $0.id == SidebarLayoutDocument.recentsSectionID }
        return earlier
    }

    @Test func theDefaultSidebarDoesNotIncludeRecents() {
        #expect(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.recentsSectionID) == nil)
    }

    @Test func anEarlierDefaultGainsRecentsOnce() throws {
        for document in [SidebarLayoutDocument.defaults, SidebarLayoutDocument.migrationTarget] {
            let stored = earlier(document)
            #expect(stored.layoutMigrationOps == [.sectionAdd(SidebarLayoutDocument.recentsSection, index: 1)])
            let migrated = stored.layoutMigration
            #expect(migrated.sections == document.sections)
            #expect(migrated.revision > stored.revision)
            #expect(migrated.layoutMigrationOps.isEmpty, "once")
        }
    }

    @Test func aChangedLayoutDoesNotGainRecents() throws {
        let changed = try SidebarLayoutReducer.reduce(earlier(.defaults), .itemRemove(LayoutItemID("itm_app_store"))).get()
        #expect(changed.layoutMigrationOps.isEmpty)
    }

    /// Once this Mac offered Recents, a layout without it is one the user removed it from.
    @Test func noRecentsOnceOffered() {
        #expect(earlier(.defaults).layoutMigrationOps(offeringRecents: false).isEmpty)
    }

}
