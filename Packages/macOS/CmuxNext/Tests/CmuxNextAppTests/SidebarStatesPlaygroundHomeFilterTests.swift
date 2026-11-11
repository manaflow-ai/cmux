import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextHome
@testable import CmuxNextSidebar
@testable import MessagesLabSidebar
import Testing

/// The Sidebar States Playground's Home filter section (a939's Unread filter, the user 2026-11-03, msg 20156): the App passes
/// it in, built from the real ``HomeSidebarView``, so each look is the real toggle, the real `HomeFilterChip` and the
/// real empty list. Each look is staged as the playground stages it (a plain root, no window) and the part it shows
/// holds the views that look is about.
@MainActor @Suite struct SidebarStatesPlaygroundHomeFilterTests {
    /// Stages `look` in a fresh root and returns the root, the shown rect and the Home list it added.
    private func staged(_ look: SidebarStatesPlaygroundLook) throws -> (root: NSView, shown: NSRect, home: HomeSidebarView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 720))
        let shown = look.stage(root)
        let home = try #require(root.subviews.compactMap { $0 as? HomeSidebarView }.first, "\(look.title): no Home list")
        #expect(!shown.isEmpty && root.bounds.contains(shown), "\(look.title): shows \(shown) of \(root.bounds)")
        return (root, shown, home)
    }

    private func frame(_ view: NSView, in root: NSView) -> NSRect { root.convert(view.bounds, from: view) }

    @Test func theHomeFilterSectionShowsTheButtonOffAndOnTheChipAndTheEmptyList() throws {
        let section = HomeFilterPlaygroundSection().section()
        #expect(section.looks.count == 3, "the filter off, the filter on and the empty list")
        #expect(Set(section.looks.map(\.title)).count == section.looks.count && !section.looks.contains { $0.title.isEmpty })
        guard section.looks.count == 3 else { return }

        // Off: the toggle at rest (no fill), no chip.
        let off = try staged(section.looks[0])
        #expect(!off.home.unreadOnly && !off.home.unreadToggle.isOn && !off.home.unreadToggle.hover.state.lit)
        #expect(off.home.filterChip.isHidden)
        #expect(off.shown.contains(frame(off.home.unreadToggle, in: off.root)), "the toggle is in the shot")

        // On: the toggle lit (its fill kept under the glyph) and the Unread × chip under the search row, both shown.
        let on = try staged(section.looks[1])
        #expect(on.home.unreadOnly && on.home.unreadToggle.isOn && on.home.unreadToggle.hover.state.lit)
        #expect(!on.home.filterChip.isHidden && on.home.filterChip.title == CmuxSidebarView.unreadTitle)
        let chip = frame(on.home.filterChip, in: on.root), search = frame(on.home.searchCapsule, in: on.root)
        #expect(chip.maxY <= search.minY + 0.5, "the chip sits under the search row: \(chip) vs \(search)")
        #expect(on.shown.contains(chip) && on.shown.contains(frame(on.home.unreadToggle, in: on.root)))

        // The empty filtered list: No Unread Chats over Show All, both in the shot.
        let empty = try staged(section.looks[2])
        let controller = empty.home.list.controller
        #expect(empty.home.unreadOnly)
        #expect(!controller.noResults.isHiddenOrHasHiddenAncestor && controller.noResults.stringValue == SidebarStrings.noUnread)
        #expect(!controller.showAll.isHiddenOrHasHiddenAncestor)
        #expect(empty.shown.contains(frame(controller.noResults, in: empty.root)), "No Unread Chats is in the shot")
        #expect(empty.shown.contains(frame(controller.showAll, in: empty.root)), "Show All is in the shot")
    }
}
