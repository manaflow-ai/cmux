import CmuxNextActions
import CmuxNextSettings
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// Leo (2026-10-06): the Recents header's menu has Hide Section; the Projects
/// header (the sidebar's menu) has Hide Projects; the sidebar's menu has Show
/// Hidden Sections to bring them back. Recents is now the optional Chats
/// section (SIDEBAR-NO-RECENTS), so its Hide turns `sidebar.showChats` off.
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
        // Recents is an app section: one Hide row, not Hide Section and the app's Hide.
        #expect(SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.recentsSectionID, isApp: true).contains("sidebar.item.hideApp"))
        #expect(SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.topSectionID, isApp: false).contains("sidebar.section.hide"))
        #expect(SidebarHiddenSections.headerMenuRemovals(SidebarLayoutDocument.topSectionID, isApp: false).contains("sidebar.item.hideApp"))
    }

    /// Live on a capture mini: the header's Hide Section did nothing when the
    /// daemon had no sidebar layout (`sidebar-layout-v1`). The target is read
    /// by id, not looked up in the layout; with no target it means Recents.
    @Test func hideSectionReadsTheTargetByID() {
        let recents = SidebarLayoutDocument.recentsSectionID
        #expect(SidebarHiddenSections.hidesRecents(ActionTargetRef(kind: .sidebarSection, id: recents.rawValue)))
        #expect(SidebarHiddenSections.hidesRecents(nil))
        #expect(!SidebarHiddenSections.hidesRecents(ActionTargetRef(kind: .sidebarSection, id: SidebarLayoutDocument.topSectionID.rawValue)))
    }

    /// One setting per section: hiding Chats from its header turns off Show
    /// Chats, and Show Hidden Sections brings back Projects only (Chats is
    /// opt in; Show Chats in Settings brings it back).
    @Test func hidingChatsTurnsOffShowChats() {
        #expect(SidebarHiddenSections.hidePath == SidebarSectionsSetting.showChatsPath)
        #expect(SidebarHiddenSections.showHiddenPaths == [SidebarSectionsSetting.showProjectsPath])
    }
}
