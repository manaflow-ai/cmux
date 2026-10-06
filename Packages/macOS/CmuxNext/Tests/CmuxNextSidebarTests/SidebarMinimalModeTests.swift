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

    /// Lawrence (2026-10-05): "settings section border should fade if im not hovered". The
    /// hairline over the bottom band (and under the top band) fades with its band; a band that
    /// stays (minimal mode off, or an item control on it) keeps its line.
    @Test func theBandLinesFadeWithTheirBands() {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        view.setChromeRevealed(true)
        view.setChromeRevealed(false)
        #expect(view.belowLine.opacity == 0, "the Settings band's border fades out at rest")
        #expect(view.aboveLine.opacity == 1, "the top band stays, so does its line")
        view.setChromeRevealed(true)
        #expect(view.belowLine.opacity == 1, "hover shows the border again")
        var info = SidebarItemInfo(title: "Settings", symbol: "gearshape")
        info.accessory = .update(title: "Restart to Update")
        view.model.itemInfo[LayoutItemID("itm_settings")] = info
        view.setChromeRevealed(false)
        #expect(view.belowLine.opacity == 1, "an update control keeps the band and its border")
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
    /// The update notice is the Settings row's control (no card, Lawrence
    /// 2026-10-05): while Settings carries it, minimal mode keeps the
    /// bottom band visible, so a staged update shows without a hover.
    @Test func anItemControlKeepsItsBandVisible() {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        var info = SidebarItemInfo(title: "Settings", symbol: "gearshape")
        info.accessory = .update(title: "Restart to Update")
        view.model.itemInfo[LayoutItemID("itm_settings")] = info
        view.setChromeRevealed(false)
        #expect(bandAlpha(view.belowRegion) == 1)
        view.model.itemInfo[LayoutItemID("itm_settings")]?.accessory = nil
        view.setChromeRevealed(false)
        #expect(bandAlpha(view.belowRegion) == 0)
    }
}
