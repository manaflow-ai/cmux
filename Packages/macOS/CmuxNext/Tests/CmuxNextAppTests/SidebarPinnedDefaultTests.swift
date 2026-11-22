import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A fresh profile's sidebar is pinned: shown, and its Settings and profile row visible with
/// the pointer elsewhere. Hover-reveal is opt-in (`sidebar.minimalMode`). Spaces stay hidden until
/// the person has a second one (Lawrence 2026-11-20: "hide spaces by default, but people can still
/// cmd shift p new space"): a lone space shows no strip, at the bottom or the top, and New Space stays
/// in the command palette. This replaces the 2026-11-01 rule (#30232) that kept a lone space's dot and
/// its + in the bottom strip.
@MainActor
struct SidebarPinnedDefaultTests {
    private func restingSidebar(spaces: Int = 1, position: SpacesPosition = .bottom) -> (SidebarModel, SidebarView) {
        let model = SidebarModel()
        model.profiles = Self.spaces(spaces)
        let sidebar = SidebarView(model: model)
        sidebar.spacesPosition = position
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

    private static func spaces(_ count: Int) -> [SidebarProfile] {
        (0..<count).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
    }

    @Test(arguments: [SpacesPosition.bottom, .top])
    func aLoneSpaceShowsNoSpacesStrip(position: SpacesPosition) {
        let (_, sidebar) = restingSidebar(position: position)
        #expect(sidebar.profileBar.isHidden, "a lone space shows the strip (\(position))")
    }

    /// The person makes a second space (the palette's New Space): the strip shows, with no setting.
    @Test func aSecondSpaceRevealsTheStrip() {
        let (model, sidebar) = restingSidebar()
        #expect(sidebar.profileBar.isHidden)
        model.profiles = Self.spaces(2)
        sidebar.needsLayout = true
        sidebar.layout()
        #expect(!sidebar.profileBar.isHidden, "two spaces and still no strip")
    }

    /// Two spaces keep the strip: it is their only on-screen switcher.
    @Test func twoSpacesKeepTheSpacesStrip() {
        let (_, sidebar) = restingSidebar(spaces: 2)
        #expect(!sidebar.profileBar.isHidden)
    }
}
