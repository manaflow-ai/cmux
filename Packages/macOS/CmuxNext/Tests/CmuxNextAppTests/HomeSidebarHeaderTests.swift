import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The Home list's header (Leo 2026-10-19, "when the thing is compressed"): on the list with names,
/// search, the Unread toggle and compose stay on one row at every width; only the search field's
/// width changes; the row sits in the 52 pt band with no lone button above it. The avatar-only
/// list shows no row (the user 2026-10-20, as Messages: `HomeNarrowSidebarTests`).
@MainActor
struct HomeSidebarHeaderTests {
    nonisolated static let widths: [CGFloat] = [180, 200, 220, 260, 300, 320, 480]

    @Test(arguments: widths)
    func everythingStaysOnOneRow(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false)
        let items = [h.search, h.filter, h.compose]
        #expect(Set(items.map(\.midY)).count == 1, "the row wraps at \(width)")
        #expect(items.allSatisfy { $0.height == HomeSidebarHeaderLayout.side })
        #expect(items.allSatisfy { $0.minX >= 0 && $0.maxX <= width }, "the row overflows \(width)")
        for (a, b) in zip(items, items.dropFirst()) {
            #expect(a.maxX <= b.minX, "items overlap at \(width)")
        }
        #expect(!h.buttonsCovered)
        #expect(h.search.width >= HomeSidebarHeaderLayout.minimumField)
        #expect(h.listTop == HomeSidebarHeaderLayout.band)
    }

    @Test func onlyTheSearchFieldGrowsWithTheWidth() {
        let narrow = HomeSidebarHeaderLayout(width: 200, searchOpen: false)
        let wide = HomeSidebarHeaderLayout(width: 400, searchOpen: false)
        #expect(wide.search.width - narrow.search.width == 200)
        #expect(narrow.filter.size == wide.filter.size)
        #expect(narrow.compose.size == wide.compose.size)
        #expect(wide.compose.maxX == 400 - HomeSidebarHeaderLayout.inset)
    }

    /// The view follows the layout: the field and the quiet buttons on one row, the field's
    /// bezel and AppKit focus ring off, and no fill on a button at rest.
    @Test(arguments: [180, 260, 320] as [CGFloat])
    func theViewDrawsTheRow(_ width: CGFloat) throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        let field = home.list.searchField
        #expect(field.focusRingType == .none)
        #expect(!field.isBezeled)
        #expect(!field.isHidden)
        #expect(!home.compose.isHidden && !home.unreadToggle.isHidden)
        #expect(home.compose.frame == home.header.compose)
        #expect(home.unreadToggle.frame == home.header.filter)
        #expect(home.compose.frame.midY == home.unreadToggle.frame.midY)
        #expect(home.searchCapsule.frame.midY == home.compose.frame.midY)
        #expect(field.frame.midY == home.compose.frame.midY)
        // MessagesLab's filter menu button is gone: the toggle is the filter.
        #expect(home.list.controller.filterButton.isHidden)
        for button in [home.compose, home.unreadToggle] {
            #expect((button.layer?.backgroundColor?.alpha ?? 0) == 0, "a header button has a pill at rest")
        }
    }

    @Test func theUnreadToggleFiltersInOneClick() {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        #expect(!home.unreadOnly)
        home.unreadToggle.performClick(nil)
        #expect(home.unreadOnly)
        #expect(home.unreadToggle.isOn)
        #expect(home.list.controller.filter == .unread)
        home.unreadToggle.performClick(nil)
        #expect(home.list.controller.filter == .all)
        #expect(!home.unreadToggle.isOn)
    }
}
