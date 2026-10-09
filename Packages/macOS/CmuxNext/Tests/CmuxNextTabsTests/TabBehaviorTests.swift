import CoreGraphics
import Foundation
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

@Suite("Tab chrome visibility")
struct VisibilityTests {
    private func resolve(_ width: CGFloat, pinned: Bool = false, selected: Bool = false, hovered: Bool = false, style: TabStripStyle = .chrome) -> TabChromeVisibility {
        TabChromeVisibility.resolve(width: width, isPinned: pinned, isSelected: selected, isHovered: hovered, style: style, metrics: m)
    }

    @Test func wideTabsShowIconAndTitleButNoCloseUntilHovered() {
        let v = resolve(200)
        #expect(v.showsIcon && v.showsTitle && !v.showsClose && !v.centersContent)
        #expect(resolve(200, hovered: true).showsClose)
    }

    /// User feedback (nxdog9): the x shows only on the hovered tab, also
    /// not on a wide selected tab while the pointer is elsewhere. A narrow
    /// selected tab keeps it (nxdog13).
    @Test func selectedTabShowsCloseOnlyWhileHoveredUntilItIsNarrow() {
        #expect(!resolve(200, selected: true).showsClose)
        #expect(resolve(200, selected: true, hovered: true).showsClose)
        #expect(resolve(m.minActiveTabWidth, selected: true).showsClose)
    }

    @Test func narrowInactiveTabHidesClose() {
        let v = resolve(80)
        #expect(!v.showsClose)
        #expect(v.showsTitle)
    }

    /// The 68 pt contents threshold (10 + 68 + 6 with these metrics).
    @Test func hoverRevealsCloseFromTheContentsWidthThreshold() {
        #expect(resolve(84, hovered: true).showsClose)
        #expect(!resolve(80, hovered: true).showsClose)
        #expect(!resolve(40, hovered: true).showsClose)
    }

    @Test func tinyHoveredActiveTabShowsOnlyCloseCentered() {
        let v = resolve(40, selected: true, hovered: true)
        #expect(v.showsClose)
        #expect(!v.showsIcon)
        #expect(!v.showsTitle)
        #expect(v.centersContent)
    }

    @Test func tokenDerivedMinActiveWidthFitsIconAndClose() {
        let tokens = TabStripMetrics.standard
        let v = TabChromeVisibility.resolve(width: tokens.minActiveTabWidth, isPinned: false, isSelected: true, isHovered: true, style: .chrome, metrics: tokens)
        #expect(v.showsIcon && v.showsClose)
    }

    @Test func minActiveWidthFitsIconAndClose() {
        let v = resolve(m.minActiveTabWidth, selected: true, hovered: true)
        #expect(v.showsIcon && v.showsClose)
    }

    @Test func tinyInactiveTabIsIconOnlyCentered() {
        let v = resolve(40)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
    }

    @Test func pinnedIsIconOnly() {
        let v = resolve(40, pinned: true, selected: true, hovered: true)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
    }

    @Test func compactShowsCloseOnlyOnTheHoveredTab() {
        #expect(!resolve(160, style: .compact).showsClose)
        #expect(resolve(160, hovered: true, style: .compact).showsClose)
        #expect(!resolve(160, selected: true, style: .compact).showsClose)
    }
}

