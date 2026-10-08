import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo (2026-10-06): a section header collapses its section, and the state
/// survives a relaunch (Chats and the other layout sections; workspace
/// sections keep theirs in the sidebar snapshot).
@MainActor @Suite struct SidebarCollapsedSectionsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "SidebarCollapsedSectionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aCollapsedSectionIsSavedAndReadBack() {
        let defaults = freshDefaults()
        let store = SidebarCollapsedSections(defaults: defaults)
        #expect(store.load().isEmpty)
        store.save([SidebarLayoutDocument.recentsSectionID])
        #expect(SidebarCollapsedSections(defaults: defaults).load() == [SidebarLayoutDocument.recentsSectionID])
    }

    @Test func togglingASectionReportsTheNewSet() {
        let model = SidebarModel()
        var reported: [Set<LayoutSectionID>] = []
        model.onCollapsedLayoutSectionsChange = { reported.append($0) }
        model.apply(.toggleLayoutSection(SidebarLayoutDocument.recentsSectionID))
        model.apply(.toggleLayoutSection(SidebarLayoutDocument.recentsSectionID))
        #expect(reported == [[SidebarLayoutDocument.recentsSectionID], []])
    }
}
