@testable import CmuxNextSidebar
import Testing

/// The sidebar document is shared by every window; a workspace in the top
/// region draws only in the window that owns it. A new window opened beside
/// one whose band holds workspaces (Add to Top, a drop on the band, a pin)
/// showed all of them; a workspace dragged to another window stayed in the
/// old window's band too.
@Suite struct SidebarLayoutWindowScopeTests {
    static let mine = "s1:ws_mine", other = "s1:ws_other", pinnedOther = "s1:ws_pinned_other", closed = "s1:ws_closed"

    static var document: SidebarLayoutDocument {
        var document = SidebarLayoutDocument.defaults
        let top = document.sections.firstIndex { $0.id == SidebarLayoutDocument.topSectionID }!
        document.sections[top].items += [mine, other, closed].map { LayoutItem(id: LayoutItemID("itm_\($0)"), ref: .workspace($0)) }
        document.sections.insert(SidebarLayoutDocument.pinnedSection(items: [LayoutItem(id: LayoutItemID("itm_p"), ref: .workspace(pinnedOther))]),
                                 at: top + 1)
        // A custom section moved to the scrolling region draws in the band above the list too.
        document.sections.append(LayoutSection(id: LayoutSectionID("sec_custom"), region: .middle,
                                               items: [LayoutItem(id: LayoutItemID("itm_c"), ref: .workspace(other)),
                                                       LayoutItem(id: LayoutItemID("itm_link"), ref: .url("https://cmux.com"))]))
        return document
    }

    static func refs(_ document: SidebarLayoutDocument, region: SidebarRegion) -> [LayoutItemRef] {
        document.sections.filter { $0.region == region }.flatMap(\.items).map(\.ref)
    }

    @Test func aWindowsBandDropsTheWorkspacesAnotherWindowOwns() {
        let elsewhere: Set<String> = [Self.other, Self.pinnedOther]
        let scoped = Self.document.scopedToWindow(ownedElsewhere: elsewhere.contains)
        #expect(Self.refs(scoped, region: .top) == [.app("cmux/home"), .app("cmux/app-store"), .workspace(Self.mine), .workspace(Self.closed)])
        #expect(scoped.section(LayoutSectionID("sec_custom"))?.items.map(\.ref) == [.url("https://cmux.com")])
        // The sections, the workspace list and the footer are untouched.
        #expect(scoped.sections.map(\.id) == Self.document.sections.map(\.id))
        #expect(Self.refs(scoped, region: .bottom) == Self.refs(Self.document, region: .bottom))
    }

    @Test func aWindowThatOwnsEveryBandWorkspaceDrawsTheDocumentAsStored() {
        #expect(Self.document.scopedToWindow { _ in false } == Self.document)
    }
}
