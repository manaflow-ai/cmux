import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (T3 Code ref, 2026-10-07): the Chats section filters its chats by
/// project from one filter button (a filter glyph, not a folder) whose menu
/// lists All projects, then each project with its colored badge. The
/// section's own search stays the only search field.
@MainActor @Suite(.serialized) struct SidebarChatsFilterTests {
    private static func row(_ id: String, _ folder: String?) -> SidebarChatsView.Row {
        SidebarChatsView.Row(id: id, title: id, harness: "codex", brand: nil, folder: folder)
    }

    private static let rows = [row("c1", "/p/alpha"), row("c2", "/p/beta"), row("c3", "/p/alpha"), row("c4", nil)]

    private func chats(_ rows: [SidebarChatsView.Row] = Self.rows) -> SidebarChatsView {
        let view = SidebarChatsView(frame: NSRect(x: 0, y: 0, width: 260, height: 400), defaults: UserDefaults(suiteName: "chats-filter-\(UUID())")!)
        view.update(rows, enabled: true, ready: true)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func oneProjectNeedsNoFilter() {
        let view = chats([Self.row("c1", "/p/alpha"), Self.row("c2", "/p/alpha")])
        #expect(view.filterButton.isHidden)
    }

    @Test func theMenuListsAllProjectsThenEachProjectWithItsBadge() {
        let view = chats()
        #expect(!view.filterButton.isHidden)
        let menu = view.projectMenu()
        #expect(menu.items.map(\.title) == [SidebarChatsView.allProjectsTitle, "alpha", "beta"], "distinct folders, newest first")
        #expect(menu.items[0].state == .on, "no filter: All projects is checked")
        #expect(menu.items[1].image != nil && menu.items[2].image != nil, "each project wears its badge")
        #expect(menu.items[2].toolTip == "/p/beta")
    }

    @Test func pickingAProjectShowsOnlyItsChatsAndAllProjectsShowsEveryChat() {
        let view = chats()
        view.projectMenu().performActionForItem(at: 1)
        #expect(view.selectedProject == "/p/alpha")
        #expect(view.shownChatIDs == ["c1", "c3"])
        #expect(view.projectMenu().items[1].state == .on)
        view.projectMenu().performActionForItem(at: 0)
        #expect(view.selectedProject == nil)
        #expect(view.shownChatIDs == ["c1", "c2", "c3", "c4"])
    }

    @Test func aFilterWhoseProjectLeavesTheListClears() {
        let view = chats()
        view.projectMenu().performActionForItem(at: 2)
        #expect(view.shownChatIDs == ["c2"])
        view.update([Self.row("c1", "/p/alpha"), Self.row("c5", "/p/gamma")], enabled: true, ready: true)
        #expect(view.selectedProject == nil)
        #expect(view.shownChatIDs == ["c1", "c5"])
    }

    @Test func theSectionKeepsOneSearchField() {
        let view = chats()
        let searches = view.subviews.filter { $0 is NSSearchField }
        #expect(searches.count == 1)
        #expect(!view.projectMenu().items.contains { $0.view is NSSearchField }, "no second search field")
    }
}
