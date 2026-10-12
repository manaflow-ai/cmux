import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A fresh profile's sidebar is pinned: shown, and its Settings and profile row visible with
/// the pointer elsewhere. Hover-reveal is opt-in (`sidebar.minimalMode`). The footer holds one
/// switcher, the profile control; no spaces strip beside it (Leo 2026-10-11).
@MainActor
struct SidebarPinnedDefaultTests {
    private func restingSidebar() -> (SidebarModel, SidebarView) {
        let model = SidebarModel()
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        // The pointer leaves the sidebar.
        sidebar.setChromeRevealed(true)
        sidebar.setChromeRevealed(false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    @Test func aFreshProfileShowsAPinnedSidebar() {
        #expect(DesignSettings.shared.sidebarSections.minimalMode == .off)
        let (model, sidebar) = restingSidebar()
        #expect(!model.isHidden)
        #expect(sidebar.footerRegion.alphaValue == 1)
        #expect(!sidebar.minimalHiddenBands.top && !sidebar.minimalHiddenBands.bottom)
    }

    @Test func theFooterHasNoSpacesStripBesideTheProfileControl() {
        let (_, sidebar) = restingSidebar()
        #expect(sidebar.profileBar.isHidden)
    }
}
