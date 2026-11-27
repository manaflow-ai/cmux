@testable import CmuxNextSidebar
import Testing

/// Filtering the preview-only App Store row must not change the resulting
/// order in the stored `sidebar-layout-v1` document.
@Suite struct SidebarPreviewRowReorderTests {
    @Test func movingVisibleHomeAfterSettingsPreservesHiddenAppStore() throws {
        let sectionID = LayoutSectionID("sec_top")
        let appStore = LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))
        let home = LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))
        let settings = LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings))
        let document = SidebarLayoutDocument(sections: [
            LayoutSection(id: sectionID, region: .top, items: [appStore, home, settings]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        // This is the filtered layout the caller passes to `op`: the
        // stored App Store row is omitted while Preview Features is off.
        let projected = SidebarLayoutDocument(sections: [
            LayoutSection(id: sectionID, region: .top, items: [home, settings]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        let shown = [LayoutSection(id: sectionID, region: .top, items: [settings, home])]

        let op = try #require(SidebarRegionReorder.op(for: .item(home.id), shown: shown, document: projected))
        #expect(op == .itemMove(home.id, section: sectionID, index: 1))
        let translated = op.translatingHiddenItemIndex(from: projected, to: document)
        #expect(translated == .itemMove(home.id, section: sectionID, index: 2))

        let result = try SidebarLayoutReducer.reduce(document, translated).get()
        let section = try #require(result.section(sectionID))
        #expect(section.items.map(\.id) == [appStore.id, settings.id, home.id])
    }

    @Test func movingVisibleHomeBeforeSettingsPreservesHiddenAppStore() throws {
        let sectionID = LayoutSectionID("sec_top")
        let appStore = LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))
        let home = LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))
        let settings = LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings))
        let document = SidebarLayoutDocument(sections: [
            LayoutSection(id: sectionID, region: .top, items: [appStore, settings, home]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        let projected = SidebarLayoutDocument(sections: [
            LayoutSection(id: sectionID, region: .top, items: [settings, home]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        let shown = [LayoutSection(id: sectionID, region: .top, items: [home, settings])]

        let op = try #require(SidebarRegionReorder.op(for: .item(home.id), shown: shown, document: projected))
        #expect(op == .itemMove(home.id, section: sectionID, index: 0))
        let translated = op.translatingHiddenItemIndex(from: projected, to: document)
        #expect(translated == .itemMove(home.id, section: sectionID, index: 1))

        let result = try SidebarLayoutReducer.reduce(document, translated).get()
        let section = try #require(result.section(sectionID))
        #expect(section.items.map(\.id) == [appStore.id, home.id, settings.id])
    }

    @Test(arguments: [0, 1, 2])
    func droppingWorkspacePinsUsesTheVisibleInsertionSlot(_ index: Int) throws {
        let sectionID = LayoutSectionID("sec_top")
        let home = LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home"))
        let appStore = LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))
        let first = LayoutItem(id: LayoutItemID("itm_first"), ref: .workspace("preview:ws_first"))
        let dropped = LayoutItem(id: LayoutItemID("itm_dropped"), ref: .workspace("preview:ws_dropped"))
        let document = SidebarLayoutDocument(sections: [
            LayoutSection(id: sectionID, region: .top, items: [home, appStore, first]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        var projected = document
        projected.sections[0].items = [home, first]
        // The same conversion as dropOnLayoutSection, before userDrop sends itemAdd.
        let storedIndex = document.storedInsertionIndex(index, in: sectionID, from: projected)
        let result = try SidebarLayoutReducer.reduce(document, .itemAdd(dropped, section: sectionID, index: storedIndex)).get()
        let items = try #require(result.section(sectionID)).items
        var expected = [home.id, first.id]
        expected.insert(dropped.id, at: index)
        #expect(items.filter { $0.id != appStore.id }.map(\.id) == expected)
        #expect(items.contains(appStore))
    }

}
