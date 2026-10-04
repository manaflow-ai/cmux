import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// R54 (Lawrence 2026-10-03): in minimal mode the chosen pinned bands fade
/// out while the pointer is away from the sidebar and fade in when it
/// hovers; VoiceOver still reaches their items.
@MainActor @Suite(.serialized) struct SidebarMinimalModeTests {
    private func sidebar(_ mode: SidebarMinimalMode) -> (SidebarView, () -> Void) {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.minimalMode = mode
        let view = SidebarView(model: SidebarModel())
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return (view, { DesignSettings.shared.sidebarSections = saved })
    }

    /// The band's alpha target: 0 while minimal mode hides it, else 1.
    private func bandAlpha(_ region: SidebarRegionView) -> CGFloat {
        guard let view = region.enclosingScrollView?.superview?.superview as? SidebarView else { return -1 }
        let hidden = region === view.aboveRegion ? view.minimalHiddenBands.top : view.minimalHiddenBands.bottom
        return hidden ? 0 : 1
    }

    @Test func theBottomBandHidesUntilThePointerHovers() {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        view.setChromeRevealed(false)
        #expect(bandAlpha(view.belowRegion) == 0)
        #expect(bandAlpha(view.aboveRegion) == 1)
        view.setChromeRevealed(true)
        #expect(bandAlpha(view.belowRegion) == 1)
        // VoiceOver still finds Settings while the band is faded.
        view.setChromeRevealed(false)
        let settings = view.belowRegion.itemView(LayoutItemID("itm_settings"))
        #expect(settings != nil && settings?.isHiddenOrHasHiddenAncestor == false && settings?.isAccessibilityElement() == true)
    }

    @Test func bothBandsHideInBothAndNoneWhenOff() {
        let (both, restoreBoth) = sidebar(.both)
        both.setChromeRevealed(false)
        #expect(bandAlpha(both.aboveRegion) == 0 && bandAlpha(both.belowRegion) == 0)
        restoreBoth()
        let (off, restoreOff) = sidebar(.off)
        defer { restoreOff() }
        off.setChromeRevealed(false)
        #expect(bandAlpha(off.aboveRegion) == 1 && bandAlpha(off.belowRegion) == 1)
    }
}
