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

    @Test func draggingAnAppToBottomUsesItsShownNeighborAndPreservesHiddenSections() throws {
        let moved = LayoutSection(id: LayoutSectionID("sec_moved"), region: .top,
                                  content: .app, contribution: "local/customize#moved")
        let hidden = LayoutSection(id: LayoutSectionID("sec_hidden"), region: .bottom,
                                   content: .app, contribution: "local/hidden#section")
        let first = LayoutSection(id: LayoutSectionID("sec_first"), region: .bottom,
                                  content: .app, contribution: "local/customize#first")
        let last = LayoutSection(id: LayoutSectionID("sec_last"), region: .bottom,
                                 content: .app, contribution: "local/customize#last")
        let document = SidebarLayoutDocument(sections: [moved, Self.workspaces, hidden, first, last])
        let op = try #require(SidebarRegionReorder.appSectionMove(moved.id, to: .bottom, before: last.id,
                                                                shown: [first, last], document: document))
        let updated = try SidebarLayoutReducer.reduce(document, op).get()

        #expect(updated.sections(in: .bottom, room: nil).map(\.id) == [hidden.id, first.id, moved.id, last.id])
        #expect(updated.sections(in: .top, room: nil).isEmpty)
    }

    @Test func draggingTheAppBackToTopKeepsTheDocumentOrder() throws {
        let moved = LayoutSection(id: LayoutSectionID("sec_moved"), region: .bottom,
                                  content: .app, contribution: "local/customize#moved")
        let top = LayoutSection(id: LayoutSectionID("sec_top_app"), region: .top,
                                content: .app, contribution: "local/customize#top")
        let document = SidebarLayoutDocument(sections: [top, Self.workspaces, moved])
        let op = try #require(SidebarRegionReorder.appSectionMove(moved.id, to: .top, before: top.id,
                                                                shown: [top], document: document))
        let updated = try SidebarLayoutReducer.reduce(document, op).get()

        #expect(updated.sections(in: .top, room: nil).map(\.id) == [moved.id, top.id])
        #expect(updated.appSections(in: .bottom, room: nil).isEmpty)
    }
}
