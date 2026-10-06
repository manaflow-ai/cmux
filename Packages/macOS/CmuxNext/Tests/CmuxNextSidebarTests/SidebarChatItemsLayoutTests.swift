import CmuxNextIcons
import Testing
@testable import CmuxNextSidebar

/// New chat and Search Chats lead the top section, as the ChatGPT desktop
/// app's sidebar opens with them. A stored layout equal to a default from
/// before them gains both through ordinary ops; a changed layout keeps its items.
@Suite struct SidebarChatItemsLayoutTests {
    private let ids = SidebarLayoutDocument.chatItems.map(\.id)

    /// A default without the chat items (and, with `recents: false`, without Recents).
    private func earlier(_ document: SidebarLayoutDocument, recents: Bool = true) -> SidebarLayoutDocument {
        var earlier = document
        earlier.revision = 5
        for s in earlier.sections.indices { earlier.sections[s].items.removeAll { ids.contains($0.id) } }
        if !recents { earlier.sections.removeAll { $0.id == SidebarLayoutDocument.recentsSectionID } }
        return earlier
    }

    @Test func theDefaultsOpenWithNewChatAndSearchChats() {
        let top = SidebarLayoutDocument.defaults.sections(in: .top, room: nil).flatMap(\.items)
        #expect(top.prefix(2).map(\.ref) == [.builtIn(.newAgentChat), .builtIn(.searchChats)])
        #expect(SidebarBuiltIn.searchChats.title == "Search Chats")
        #expect(SidebarBuiltIn.searchChats.icon == .search)
    }

    @Test func anEarlierDefaultGainsBothOnce() {
        for document in [SidebarLayoutDocument.defaults, SidebarLayoutDocument.migrationTarget] {
            for recents in [true, false] {
                let stored = earlier(document, recents: recents)
                let migrated = stored.layoutMigration
                #expect(migrated.sections == document.sections, "recents: \(recents)")
                #expect(migrated.revision > stored.revision)
                #expect(migrated.layoutMigrationOps.isEmpty, "once")
            }
        }
        let ops = earlier(.defaults).layoutMigrationOps
        #expect(ops == SidebarLayoutDocument.chatItems.enumerated().map {
            .itemAdd($0.element, section: SidebarLayoutDocument.topSectionID, index: $0.offset)
        })
    }

    @Test func aChangedLayoutDoesNotGainThem() throws {
        let changed = try SidebarLayoutReducer.reduce(earlier(.defaults), .itemRemove(LayoutItemID("itm_app_store"))).get()
        #expect(changed.chatItemsMigrationOps.isEmpty)
        // One item kept: the user removed the other.
        let one = try SidebarLayoutReducer.reduce(.defaults, .itemRemove(SidebarLayoutDocument.searchChatsItemID)).get()
        #expect(one.layoutMigrationOps.isEmpty)
    }

    /// Once this Mac offered them, a layout without them is one the user removed them from.
    @Test func noChatItemsOnceOffered() {
        #expect(earlier(.defaults).layoutMigrationOps(offeringRecents: true, offeringChatItems: false).isEmpty)
        // Recents still arrives on its own.
        let ops = earlier(.defaults, recents: false).layoutMigrationOps(offeringRecents: true, offeringChatItems: false)
        #expect(ops == [.sectionAdd(SidebarLayoutDocument.recentsSection, index: 1)])
    }
}
