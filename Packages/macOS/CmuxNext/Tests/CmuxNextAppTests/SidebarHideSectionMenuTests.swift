import CmuxNextActions
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// Leo (2026-10-06): the Recents header's menu has Hide Section; the Projects
/// header (the sidebar's menu) has Hide Projects; the sidebar's menu has Show
/// Hidden Sections to bring them back.
@MainActor @Suite struct SidebarHideSectionMenuTests {
    private func ids(_ context: ActionMenuContext) -> [ActionID] {
        ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
    }

    @Test func theMenusOfferHideAndShow() {
        #expect(ids(.sidebarSection).contains("sidebar.section.hide"))
        #expect(ids(.sidebarBackground).contains("sidebar.projects.hide"))
        #expect(ids(.sidebarBackground).contains("sidebar.sections.showHidden"))
    }

    @Test func onlyRecentsHidesFromItsHeader() {
        #expect(!SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.recentsSectionID, isApp: false).contains("sidebar.section.hide"))
        #expect(SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.topSectionID, isApp: false).contains("sidebar.section.hide"))
        #expect(SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.topSectionID, isApp: false).contains("sidebar.item.hideApp"))
    }
}
