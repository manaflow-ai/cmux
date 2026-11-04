import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// Regression for HQ #4743: crowded tabs expose a visible close target on
/// hover. The unhovered icon keeps its original center; TabCell uses
/// centersContent to put the replacement close glyph there. A pinned tab no
/// longer does: it keeps its icon and closes from its right-click menu
/// (Lawrence msg 19392).
@MainActor @Suite(.serialized) struct TabHoverCloseVisibilityTests {
    // Fixed narrow fixture: the app's scroll-overflow setting can otherwise
    // raise the minimum inactive width to the normal icon+close width.
    private let metrics: TabStripMetrics = {
        var values = TabStripMetrics.standard
        values.minInactiveTabWidth = 32
        return values
    }()

    @Test func pinnedTabsKeepTheirIconAndShowNoCloseOnHover() {
        for style in [TabStripStyle.chrome, .compact] {
            for selected in [false, true] {
                let normal = TabChromeVisibility.resolve(
                    width: 48, isPinned: true, isSelected: selected, isHovered: false,
                    isClosable: true, style: style, metrics: metrics)
                let hovered = TabChromeVisibility.resolve(
                    width: 48, isPinned: true, isSelected: selected, isHovered: true,
                    isClosable: true, style: style, metrics: metrics)
                #expect(normal.showsIcon && !normal.showsClose)
                #expect(hovered.showsIcon && !hovered.showsClose && !hovered.showsTitle)
                #expect(hovered.centersContent)
            }
        }
    }

    @Test func unclosablePinnedTabKeepsItsIconEvenOnHover() {
        for style in [TabStripStyle.chrome, .compact] {
            let hovered = TabChromeVisibility.resolve(
                width: 48, isPinned: true, isSelected: true, isHovered: true,
                isClosable: false, style: style, metrics: metrics)
            #expect(hovered.showsIcon && !hovered.showsClose)
            #expect(hovered.centersContent)
        }
    }

    @Test func hoveredCrowdedInactiveChromeTabReplacesIconWithClose() {
        // An inactive tab at the minimum visible width has room for one
        // centered control, but not for both the favicon and close glyph.
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        #expect(width < metrics.faviconCloseWidth)
        let normal = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: false,
            style: .chrome, metrics: metrics)
        let hovered = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        #expect(normal.showsIcon && !normal.showsClose)
        #expect(hovered.showsClose && !hovered.showsIcon && !hovered.showsTitle)
        #expect(hovered.centersContent)
    }

    @Test func unclosableCrowdedTabNeverExposesClose() {
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        let hovered = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            isClosable: false, style: .chrome, metrics: metrics)
        #expect(hovered.showsIcon && !hovered.showsClose)
    }

    @Test func roomyHoveredTabKeepsIconAndCloseTogether() {
        let width = max(
            metrics.faviconCloseWidth,
            metrics.contentLeadingInset + metrics.contentTrailingInset + metrics.closeMinContentsWidth
        ) + 4
        let hovered = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        #expect(hovered.showsIcon && hovered.showsClose)
    }

    @Test func selectedNarrowTabKeepsItsExistingRestingClose() {
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        let selected = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: true, isHovered: false,
            style: .chrome, metrics: metrics)
        #expect(selected.showsClose)
    }

    @Test func accessibilityAndPaintShareTheSameCenteredCloseOrigin() {
        // A hovered pinned tab draws no x, so neither paint nor accessibility has an origin for it.
        let pinned = TabChromeVisibility.resolve(
            width: 48, isPinned: true, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        let pinnedPill = metrics.pillFrame(slotWidth: 48, height: metrics.tabHeight)
        #expect(pinned.closeButtonOriginX(pillWidth: pinnedPill.width, metrics: metrics) == nil)

        let narrowWidth = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        let narrow = TabChromeVisibility.resolve(
            width: narrowWidth, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        let narrowPill = metrics.pillFrame(slotWidth: narrowWidth, height: metrics.tabHeight)
        #expect(narrow.closeButtonOriginX(pillWidth: narrowPill.width, metrics: metrics)
                == (narrowPill.width - metrics.closeButtonSize) / 2)

        let protected = TabChromeVisibility.resolve(
            width: 48, isPinned: true, isSelected: false, isHovered: true,
            isClosable: false, style: .chrome, metrics: metrics)
        #expect(protected.closeButtonOriginX(pillWidth: pinnedPill.width, metrics: metrics) == nil)
    }

    @Test func transitionalTooNarrowTabStaysHidden() {
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth) - 1
        let hovered = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        #expect(!hovered.showsIcon && !hovered.showsClose && !hovered.showsTitle)
    }
}
