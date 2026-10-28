import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A fresh profile's sidebar is pinned: shown, and its Settings and profile row visible with
/// the pointer elsewhere. Hover-reveal is opt-in (`sidebar.minimalMode`). With one space the
/// footer holds one switcher, the profile control: no space dot beside it (Leo 2026-10-11), only the
/// "+" for a new space (Lawrence 2026-10-27).
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

    /// A lone space draws no dot (Leo 2026-10-11: it read as a duplicate switcher beside the profile
    /// control), but the "+" for a new space shows at rest, centered where the dot would be
    /// (Lawrence 2026-10-27: "the plus button for new space needs to be visible by default too").
    @Test func aLoneSpaceShowsOnlyThePlusBesideTheProfileControl() {
        let (_, sidebar) = restingSidebar()
        let bar = sidebar.profileBar
        #expect(!bar.isHidden && bar.alphaValue == 1, "the strip with the + shows at rest")
        #expect(bar.drawnDotCount == 0, "a lone space draws no dot")
        #expect(bar.showsPlus)
        let plus = bar.slotRects()[1]
        let lone = bar.slotRects()[0]
        #expect(lone.width == 0, "the lone space's slot takes no room: \(lone)")
        let center = bar.centerX ?? bar.bounds.midX
        #expect(abs(plus.midX - center) <= 1, "the + \(plus) centers on the strip's middle \(center)")
    }

    /// Two spaces keep the strip: it is their only on-screen switcher.
    @Test func twoSpacesKeepTheSpacesStrip() {
        let (_, sidebar) = restingSidebar(spaces: 2)
        #expect(!sidebar.profileBar.isHidden)
    }
}
