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

    /// The band's alpha target: 0 while minimal mode hides it, else 1. The
    /// pinned footer region is the sidebar's own subview; the bands scroll.
    private func bandAlpha(_ region: SidebarRegionView) -> CGFloat {
        guard let view = (region.enclosingScrollView?.superview?.superview ?? region.superview) as? SidebarView else { return -1 }
        let hidden = region === view.aboveRegion ? view.minimalHiddenBands.top : view.minimalHiddenBands.bottom
        return hidden ? 0 : 1
    }

    @Test func theBottomBandHidesUntilThePointerHovers() {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        view.setChromeRevealed(false)
        #expect(bandAlpha(view.belowRegion) == 0 && bandAlpha(view.footerRegion) == 0)
        #expect(bandAlpha(view.aboveRegion) == 1)
        view.setChromeRevealed(true)
        #expect(bandAlpha(view.belowRegion) == 1 && bandAlpha(view.footerRegion) == 1)
        // VoiceOver still finds the profile control while the band is faded.
        view.setChromeRevealed(false)
        let account = view.footerRegion.itemView(LayoutItemID("itm_account"))
        #expect(account != nil && account?.isHiddenOrHasHiddenAncestor == false && account?.isAccessibilityElement() == true)
    }

    /// Lawrence (2026-10-05): "settings section border should fade if im not hovered". The
    /// hairline under the top band fades with its band; the footer has no line over it at all
    /// (SIDEBAR-FOOTER-MINIMAL, Lawrence 2026-10-06).
    @Test func theTopBandLineFadesWithItsBand() {
        let (view, restore) = sidebar(.top)
        defer { restore() }
        view.setChromeRevealed(true)
        view.setChromeRevealed(false)
        #expect(view.aboveLine.opacity == 0, "the top band's border fades out at rest")
        view.setChromeRevealed(true)
        #expect(view.aboveLine.opacity == 1, "hover shows the border again")
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
    /// The update card is the only update notice (UPDATE-CARD): it is the sidebar's
    /// own view, so it stays visible while minimal mode fades the bottom band.
    @Test func theUpdateCardStaysWhileTheBottomBandFades() async {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        view.model.updateCard = SidebarUpdateCardTests.card
        for _ in 0..<200 where view.updateCardView.card == nil { await Task.yield() }
        view.setChromeRevealed(false)
        view.layoutSubtreeIfNeeded()
        #expect(bandAlpha(view.belowRegion) == 0)
        #expect(!view.updateCardView.isHiddenOrHasHiddenAncestor && view.updateCardView.alphaValue == 1)
        #expect(view.updateCardView.frame.width > 0)
    }
}
