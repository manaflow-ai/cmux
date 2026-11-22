import AppKit
import Testing
@testable import CmuxNextSidebar

/// The agent cursor's other-workspace indicator points at the workspace's
/// sidebar row, computed from the layout so virtualized rows answer too
/// (CURSOR-HIDDEN).
@MainActor @Suite struct SidebarRowAnchorTests {
    private func sidebar() -> SidebarView {
        let view = SidebarView(model: SidebarModel(sections: fixture()))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func listedWorkspacesAnswerTheirRowsInOrder() throws {
        let view = sidebar()
        let a = try #require(SidebarRowAnchor.workspaceRow(id("a"), in: view))
        let b = try #require(SidebarRowAnchor.workspaceRow(id("b"), in: view))
        #expect(a.height > 0 && a.width > 0)
        #expect(b.minY > a.minY)
    }

    @Test func aWorkspaceInACollapsedGroupAnswersTheGroupRow() throws {
        let view = sidebar()
        let h1 = try #require(SidebarRowAnchor.workspaceRow(id("h1"), in: view))
        let h2 = try #require(SidebarRowAnchor.workspaceRow(id("h2"), in: view))
        #expect(h1 == h2)
        let row = try #require(view.list.displayed.row(for: .group(g2)))
        #expect(h1 == view.list.convert(view.list.frame(for: row), to: view))
    }

    @Test func anUnlistedWorkspaceHasNoRow() {
        #expect(SidebarRowAnchor.workspaceRow(id("not-listed"), in: sidebar()) == nil)
    }

    /// The home workspace has no list row while the Home item shows (the
    /// default layout): its anchor is the Home item's row.
    @Test func theHomeItemAnswersItsRow() throws {
        let view = sidebar()
        let home = try #require(SidebarRowAnchor.layoutItem(SidebarLayoutDocument.homeRef, in: view))
        #expect(home.width > 0 && home.height > 0)
        let item = try #require(view.model.layout.firstItem(with: SidebarLayoutDocument.homeRef))
        let row = try #require(view.aboveRegion.itemView(item.id))
        #expect(home == row.convert(row.bounds, to: view))
    }

    @Test func aRefWithNoShownItemHasNoRow() {
        #expect(SidebarRowAnchor.layoutItem(.app("example/not-in-layout"), in: sidebar()) == nil)
    }

    @Test func aRowOutsideTheVisibleListIsPinnedToItsEdge() {
        let area = CGRect(x: 0, y: 100, width: 240, height: 300)
        #expect(SidebarRowAnchor.clamped(CGRect(x: 8, y: 900, width: 224, height: 28), into: area) == CGRect(x: 8, y: 372, width: 224, height: 28))
        #expect(SidebarRowAnchor.clamped(CGRect(x: 8, y: 0, width: 224, height: 28), into: area) == CGRect(x: 8, y: 100, width: 224, height: 28))
    }
}
