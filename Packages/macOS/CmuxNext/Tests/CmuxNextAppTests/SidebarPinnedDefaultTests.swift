import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A fresh profile's sidebar is pinned: shown, and its Settings and profile row visible with
/// the pointer elsewhere. Hover-reveal is opt-in (`sidebar.minimalMode`). With one space the
/// bottom strip still shows that space's dot, the hover target for its + (#30232, Leo 2026-11-01:
/// "we need for when there's only the existing space for the white dot at the bottom to be
/// visible and for the plus sign to be acceessible"). This replaces the 2026-10-11 rule that hid
/// the strip for a lone space.
@MainActor
struct SidebarPinnedDefaultTests {
    private func restingSidebar(spaces: Int = 1) -> (SidebarModel, SidebarView) {
        let model = SidebarModel()
        model.profiles = (0..<spaces).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        // The pointer leaves the sidebar.
        sidebar.setChromeRevealed(true)
        sidebar.setChromeRevealed(false)
        sidebar.layout()
        return (model, sidebar)
    }

    @Test func aFreshProfileShowsAPinnedSidebar() {
        #expect(DesignSettings.shared.sidebarSections.minimalMode == .off)
        let (model, sidebar) = restingSidebar()
        #expect(!model.isHidden)
        #expect(sidebar.footerRegion.alphaValue == 1)
        #expect(!sidebar.minimalHiddenBands.top && !sidebar.minimalHiddenBands.bottom)
    }

    @Test func aLoneSpaceKeepsItsDotInTheBottomStrip() {
        let (_, sidebar) = restingSidebar()
        #expect(!sidebar.profileBar.isHidden)
    }

    /// Two spaces keep the strip: it is their only on-screen switcher.
    @Test func twoSpacesKeepTheSpacesStrip() {
        let (_, sidebar) = restingSidebar(spaces: 2)
        #expect(!sidebar.profileBar.isHidden)
    }
}
