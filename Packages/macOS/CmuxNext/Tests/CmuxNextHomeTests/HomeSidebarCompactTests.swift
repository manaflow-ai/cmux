import AppKit
@testable import CmuxNextHome
import Testing

/// nxdog64-v1: at the compact (avatar-only) width the Home list showed its
/// search field clipped to "Sea". Like Messages, the compact list shows no
/// clipped field: it hides, and comes back when the list widens.
@MainActor @Suite struct HomeSidebarCompactTests {
    @Test func theSearchFieldHidesInTheCompactListAndReturnsWhenWide() {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 76, height: 600))
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.list.searchHidden, "no clipped search field at 76 pt")
        sidebar.setFrameSize(NSSize(width: 320, height: 600))
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.list.searchHidden, "the field returns at 320 pt")
    }
}
