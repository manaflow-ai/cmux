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

    // Leo 2026-11-05: "the button replaces the spinner on the top when you hover over it, like just like the
    // sidebar with the workspaces". A hovered tab with a status shows only the x, in the status's slot.

    private var roomyWidth: CGFloat {
        max(metrics.faviconCloseWidth, metrics.contentLeadingInset + metrics.contentTrailingInset + metrics.closeMinContentsWidth) + 80
    }

    @Test func hoveredTitledTabWithStatusShowsOnlyTheClose() {
        for style in [TabStripStyle.chrome, .compact] {
            for selected in [false, true] {
                let hovered = TabChromeVisibility.resolve(
                    width: roomyWidth, isPinned: false, isSelected: selected, isHovered: true,
                    hasStatus: true, style: style, metrics: metrics)
                #expect(hovered.showsClose && hovered.closeReplacesStatus)
                // The favicon and the title stay: only the trailing status yields to the x.
                #expect(hovered.showsIcon && hovered.showsTitle)
                let idle = TabChromeVisibility.resolve(
                    width: roomyWidth, isPinned: false, isSelected: selected, isHovered: true,
                    hasStatus: false, style: style, metrics: metrics)
                #expect(idle.showsClose && !idle.closeReplacesStatus)
                let rest = TabChromeVisibility.resolve(
                    width: roomyWidth, isPinned: false, isSelected: selected, isHovered: false,
                    hasStatus: true, style: style, metrics: metrics)
                #expect(!rest.closeReplacesStatus)
            }
        }
    }

    @Test func untitledHoveredTabWithStatusGivesTheCloseItsIconSlot() {
        // Wide enough for the icon and the x, too narrow for a title (an inactive tab, whose x shows only on hover): the status draws on the icon,
        // so the x takes the icon's centered slot instead of drawing beside it.
        let width = metrics.faviconCloseWidth
        let plain = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            style: .chrome, metrics: metrics)
        #expect(plain.showsIcon && plain.showsClose && !plain.showsTitle)
        let busy = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: false, isHovered: true,
            hasStatus: true, style: .chrome, metrics: metrics)
        #expect(!busy.showsIcon && busy.showsClose && busy.centersContent && busy.closeReplacesStatus)
        let pill = metrics.pillFrame(slotWidth: width, height: metrics.tabHeight)
        #expect(busy.closeButtonOriginX(pillWidth: pill.width, metrics: metrics) == (pill.width - metrics.closeButtonSize) / 2)
    }

    @Test func restingCloseKeepsTheStatusBesideIt() {
        // A narrow selected tab shows its x at rest: the status stays, as before.
        let width = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        let rest = TabChromeVisibility.resolve(
            width: width, isPinned: false, isSelected: true, isHovered: false,
            hasStatus: true, style: .chrome, metrics: metrics)
        #expect(rest.showsClose && !rest.closeReplacesStatus)
    }

    @Test func hoveringANarrowSelectedTabKeepsTheStatusBesideItsRestingClose() {
        // Codex review of #36837 (F1): the x already shows at rest, so hover changes nothing and the
        // status stays beside it, at every narrow width, titled or not, and along a width path.
        let narrowest = min(metrics.minInactiveTabWidth, metrics.chrome.minInactiveWidth)
        let roomyFrom = metrics.contentLeadingInset + metrics.contentTrailingInset + metrics.closeMinContentsWidth
        var widths: [CGFloat] = []
        var width = narrowest
        while width < roomyFrom { widths.append(width); width += 4 }
        #expect(!widths.isEmpty)
        for width in widths {
            let rest = TabChromeVisibility.resolve(
                width: width, isPinned: false, isSelected: true, isHovered: false,
                hasStatus: true, style: .chrome, metrics: metrics)
            let hovered = TabChromeVisibility.resolve(
                width: width, isPinned: false, isSelected: true, isHovered: true,
                hasStatus: true, style: .chrome, metrics: metrics)
            #expect(rest.showsClose && hovered.showsClose)
            #expect(!hovered.closeReplacesStatus, "width \(width)")
            #expect(hovered == rest, "width \(width)")
        }
        let forms = TabChromeVisibility.path(
            widths: widths, from: TabChromeVisibility.resolve(
                width: widths[0], isPinned: false, isSelected: true, isHovered: true,
                hasStatus: true, style: .chrome, metrics: metrics),
            isPinned: false, isSelected: true, isHovered: true, hasStatus: true, style: .chrome, metrics: metrics)
        #expect(forms.allSatisfy { !$0.closeReplacesStatus })
    }

    @Test func statusNeverGivesWayToACloseThatDoesNotShow() {
        let pinned = TabChromeVisibility.resolve(
            width: 48, isPinned: true, isSelected: false, isHovered: true,
            hasStatus: true, style: .chrome, metrics: metrics)
        #expect(pinned.showsIcon && !pinned.showsClose && !pinned.closeReplacesStatus)
        let protected = TabChromeVisibility.resolve(
            width: roomyWidth, isPinned: false, isSelected: true, isHovered: true,
            isClosable: false, hasStatus: true, style: .chrome, metrics: metrics)
        #expect(!protected.showsClose && !protected.closeReplacesStatus)
    }

    @Test func widthPathKeepsTheCloseInTheStatusSlot() {
        let widths: [CGFloat] = [roomyWidth - 40, roomyWidth - 20, roomyWidth]
        let start = TabChromeVisibility.resolve(
            width: widths[0], isPinned: false, isSelected: false, isHovered: true,
            hasStatus: true, style: .chrome, metrics: metrics)
        let forms = TabChromeVisibility.path(
            widths: widths, from: start, isPinned: false, isSelected: false, isHovered: true,
            hasStatus: true, style: .chrome, metrics: metrics)
        #expect(forms.allSatisfy { $0.showsClose && $0.closeReplacesStatus })
    }
}
