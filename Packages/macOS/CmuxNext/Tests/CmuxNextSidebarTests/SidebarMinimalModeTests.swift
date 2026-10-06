import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Sidebar chrome keeps its final frame in every minimal-mode state. Pointer
/// tracking can change paint, but it never mounts or removes the bands.
@MainActor @Suite(.serialized) struct SidebarMinimalModeTests {
    private func sidebar(_ mode: SidebarMinimalMode) -> (SidebarView, () -> Void) {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.minimalMode = mode
        let view = SidebarView(model: SidebarModel())
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return (view, { DesignSettings.shared.sidebarSections = saved })
    }

    /// The band's stable visibility target.
    private func bandAlpha(_ region: SidebarRegionView) -> CGFloat {
        guard let view = region.enclosingScrollView?.superview?.superview as? SidebarView else { return -1 }
        let hidden = region === view.aboveRegion ? view.minimalHiddenBands.top : view.minimalHiddenBands.bottom
        return hidden ? 0 : 1
    }

    @Test func theBottomBandStaysMountedAwayFromThePointer() {
        let (view, restore) = sidebar(.bottom)
        defer { restore() }
        view.setChromeRevealed(false)
        #expect(bandAlpha(view.belowRegion) == 1)
        #expect(bandAlpha(view.aboveRegion) == 1)
        view.setChromeRevealed(true)
        #expect(bandAlpha(view.belowRegion) == 1)
        // Settings remains in place while the pointer state changes.
        view.setChromeRevealed(false)
        let settings = view.belowRegion.itemView(LayoutItemID("itm_settings"))
        #expect(settings != nil && settings?.isHiddenOrHasHiddenAncestor == false && settings?.isAccessibilityElement() == true)
    }

    @Test func bothBandsStayMountedInEveryMode() {
        let (both, restoreBoth) = sidebar(.both)
        both.setChromeRevealed(false)
        #expect(bandAlpha(both.aboveRegion) == 1 && bandAlpha(both.belowRegion) == 1)
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
        #expect(bandAlpha(view.belowRegion) == 1)
    }
}
