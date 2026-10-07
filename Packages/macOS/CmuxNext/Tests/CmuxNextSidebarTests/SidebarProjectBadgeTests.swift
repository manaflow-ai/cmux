import AppKit
import Testing
@testable import CmuxNextSidebar

/// Leo (T3 Code ref, 2026-10-07): each project in the filter menu wears a
/// colored two-letter badge: its folder name's first and last letters, in a
/// color that stays the same for the same project.
struct SidebarProjectBadgeTests {
    @Test func theBadgeIsTheFoldersFirstAndLastLetters() {
        #expect(SidebarProjectBadge(path: "/Users/me/Projects").letters == "PS")
        #expect(SidebarProjectBadge(path: "/Users/me/preflight").letters == "PT")
        #expect(SidebarProjectBadge(path: "/Users/me/ourchival/").letters == "OL")
        #expect(SidebarProjectBadge(path: "/srv/x").letters == "X")
        #expect(SidebarProjectBadge(path: "/srv/my-app").letters == "MP")
        #expect(SidebarProjectBadge(path: "/srv/idlesse").name == "idlesse")
    }

    @Test func theColorIsStablePerProject() {
        let one = SidebarProjectBadge(path: "/Users/me/preflight")
        #expect(one.colorIndex == SidebarProjectBadge(path: "/Users/me/preflight").colorIndex)
        #expect((0..<SidebarProjectBadge.palette.count).contains(one.colorIndex))
    }

    @MainActor @Test func theBadgeDrawsAnImage() {
        let image = SidebarProjectBadge(path: "/srv/idlesse").image()
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}
