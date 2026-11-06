@testable import CmuxNextSidebar
import Testing

/// App sections are the only content allowed in the pinned band below the
/// workspace list. Ordinary item sections can remain in the stored document
/// for compatibility, but the bottom slot must not draw them.
@Suite struct SidebarAppBottomBandTests {
    private static let workspaces = LayoutSection(id: SidebarLayoutDocument.workspacesSectionID,
                                                   region: .middle, content: .workspaces)

    @Test func bottomBandProjectionKeepsOnlyBottomAppSections() {
        let topApp = LayoutSection(id: LayoutSectionID("sec_top_app"), region: .top,
                                   content: .app, contribution: "local/customize#top")
        let bottomItem = LayoutSection(id: LayoutSectionID("sec_bottom_item"), title: "Pinned", region: .bottom,
                                       items: [LayoutItem(id: LayoutItemID("itm_pinned"),
                                                                            ref: .url("https://cmux.com"))])
        let bottomApp = LayoutSection(id: LayoutSectionID("sec_bottom_app"), region: .bottom,
                                      content: .app, contribution: "local/customize#prs")
        let document = SidebarLayoutDocument(sections: [topApp, Self.workspaces, bottomItem, bottomApp])

        #expect(document.appSections(in: .bottom, room: nil).map(\.id) == [bottomApp.id])
        #expect(document.appSections(in: .top, room: nil).map(\.id) == [topApp.id])
    }

    @Test func appSectionsRespectRoomScopeAndDocumentOrder() {
        let first = LayoutSection(id: LayoutSectionID("sec_first"), region: .bottom,
                                 room: "work", content: .app, contribution: "local/customize#first")
        let second = LayoutSection(id: LayoutSectionID("sec_second"), region: .bottom,
                                  room: nil, content: .app, contribution: "local/customize#second")
        let document = SidebarLayoutDocument(sections: [Self.workspaces, first, second])

        #expect(document.appSections(in: .bottom, room: "work").map(\.id) == [first.id, second.id])
        #expect(document.appSections(in: .bottom, room: "other").map(\.id) == [second.id])
    }
}
