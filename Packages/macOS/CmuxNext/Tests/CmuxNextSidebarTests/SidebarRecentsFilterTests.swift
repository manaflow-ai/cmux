import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (T3 Code ref, 2026-10-07): Recents filters its chats by project from
/// one filter button (a filter glyph, not a folder) whose menu lists All
/// projects, then each project with its colored badge. There is no search
/// field of its own.
@MainActor struct SidebarRecentsFilterTests {
    private func recents() -> SidebarRecentsView {
        let view = SidebarRecentsView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.update([.init(id: "c1", title: "One", brand: nil), .init(id: "c2", title: "Two", brand: nil)])
        return view
    }

    @Test func oneProjectNeedsNoFilter() {
        let view = recents()
        view.updateProjects(["/p/alpha"], selected: nil)
        #expect(!view.showsFilter)
        view.layoutSubtreeIfNeeded()
        #expect(view.filterBar.isHidden)
    }

    @Test func theMenuListsAllProjectsThenEachProjectWithItsBadge() throws {
        let view = recents()
        view.updateProjects(["/p/alpha", "/p/beta"], selected: nil)
        #expect(view.showsFilter)
        let menu = view.projectMenu()
        #expect(menu.items.map(\.title) == [SidebarRecentsView.allProjectsTitle, "alpha", "beta"])
        #expect(menu.items[0].state == .on, "no filter: All projects is checked")
        #expect(menu.items[1].image != nil && menu.items[2].image != nil, "each project wears its badge")
        #expect(menu.items[2].toolTip == "/p/beta")
        #expect(!menu.items.contains { $0.view is NSSearchField }, "no second search field")
        #expect(view.filterButton.image != nil)
    }

    @Test func pickingAProjectFiltersAndAllProjectsClearsIt() {
        let view = recents()
        view.updateProjects(["/p/alpha", "/p/beta"], selected: nil)
        var picked: [String?] = []
        view.onFilter = { picked.append($0) }
        view.projectMenu().performActionForItem(at: 2)
        view.projectMenu().performActionForItem(at: 0)
        #expect(picked == ["/p/beta", nil])
    }

    @Test func aFilteredListNamesItsProjectAndKeepsTheFilter() {
        let view = recents()
        view.updateProjects(["/p/beta"], selected: "/p/beta")
        #expect(view.showsFilter, "a filter stays reachable even if its project is the only one left")
        #expect(view.projectMenu().items[1].state == .on)
        #expect(view.filterLabel.stringValue == "beta")
    }

    @Test func theFilterRowSitsAboveTheRows() {
        let view = recents()
        view.updateProjects(["/p/alpha", "/p/beta"], selected: nil)
        view.layoutSubtreeIfNeeded()
        #expect(!view.filterBar.isHidden)
        #expect(SidebarRecentsView.height(rows: 2, filter: true) == Metrics.sidebarRowHeight * 3)
        #expect(SidebarRecentsView.height(rows: 2) == Metrics.sidebarRowHeight * 2)
        let first = view.subviews.compactMap { $0 as? SidebarItemRowView }.map(\.frame.minY).min()
        #expect(first == Metrics.sidebarRowHeight)
    }
}
