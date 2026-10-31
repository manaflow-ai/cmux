import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// Regression for HQ #4743: closable pinned and crowded tabs expose a visible
/// close target on hover. The unhovered icon keeps its original center;
/// TabCell uses centersContent to put the replacement close glyph there.
@MainActor @Suite(.serialized) struct TabHoverCloseVisibilityTests {
    private let metrics = TabStripMetrics.standard

    @Test func pinnedTabsSwapTheirIconForTheCloseOnHover() {
        for style in [TabStripStyle.chrome, .compact] {
            let normal = TabChromeVisibility.resolve(
                width: 48, isPinned: true, isSelected: false, isHovered: false,
                isClosable: true, style: style, metrics: metrics)
            let hovered = TabChromeVisibility.resolve(
                width: 48, isPinned: true, isSelected: false, isHovered: true,
                isClosable: true, style: style, metrics: metrics)
            #expect(normal.showsIcon && !normal.showsClose)
            #expect(hovered.showsClose && !hovered.showsIcon && !hovered.showsTitle)
            #expect(hovered.centersContent)
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

    @Test func transitionalTooNarrowTabStaysHidden() {
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth) - 1
        let hovered = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        #expect(!hovered.showsIcon && !hovered.showsClose && !hovered.showsTitle)
    }
}
