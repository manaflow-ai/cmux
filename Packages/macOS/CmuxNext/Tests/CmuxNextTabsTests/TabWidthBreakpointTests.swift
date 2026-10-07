import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// Narrow tabs follow Chromium's breakpoints (user request on nxdog13:
/// handle small tabs better). Chromium `Tab::UpdateIconVisibility`
/// and `Tab::Layout` decide from the tab's contents width (its width less
/// both content insets):
/// - an inactive tab shows its favicon while it fits and otherwise centers
///   it; its title shows whenever any width is left after the favicon; it
///   has a close button only when the contents are at least
///   `kMinimumContentsWidthForCloseButtons` (68) wide;
/// - the active tab always has a close button, then the favicon if it
///   still fits, then the title in what is left (so a narrow active tab is
///   favicon and x only);
/// - a tab narrower than the minimum inactive width shows nothing.
/// cmux keeps the x hover-only on wide tabs (nxdog9) and shows it on the
/// selected tab only once that tab is narrow, where the x costs no title
/// text. Numbers use the compact density tokens.
@Suite("Tab width breakpoints")
struct TabWidthBreakpointTests {
    let t = TabStripMetrics.standard
    private func resolve(_ width: CGFloat, selected: Bool = false, hovered: Bool = false, pinned: Bool = false) -> TabChromeVisibility {
        TabChromeVisibility.resolve(width: width, isPinned: pinned, isSelected: selected, isHovered: hovered, style: .chrome, metrics: t)
    }

    /// Contents width for a tab of `width`.
    private func contents(_ width: CGFloat) -> CGFloat { width - t.contentLeadingInset - t.contentTrailingInset }
    /// The narrowest tab that shows `title` points of title after its icon.
    private func widthShowing(title: CGFloat) -> CGFloat {
        t.contentLeadingInset + t.iconSize + t.iconTitleSpacing + title + t.contentTrailingInset
    }

    @Test func narrowInactiveTabsShowTheStartOfTheirTitle() {
        let width = widthShowing(title: Metrics.space5)
        #expect(width < t.minInactiveTabWidth * 2, "well below the old two-icon threshold")
        let v = resolve(width)
        #expect(v.showsIcon && v.showsTitle && !v.showsClose && !v.centersContent)
    }

    @Test func belowThatTheInactiveTabIsItsCenteredFavicon() {
        let v = resolve(widthShowing(title: Metrics.space5) - Metrics.space2)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
        let smallest = resolve(t.minInactiveTabWidth)
        #expect(smallest.showsIcon && !smallest.showsTitle && smallest.centersContent)
    }

    @Test func hoveredInactiveTabsGetAnXOnlyFromChromesContentsWidth() {
        let threshold = t.contentLeadingInset + 68 + t.contentTrailingInset
        #expect(!resolve(threshold - Metrics.space1, hovered: true).showsClose)
        let v = resolve(threshold, hovered: true)
        #expect(v.showsClose && v.showsIcon && v.showsTitle)
        #expect(!resolve(threshold).showsClose, "hover-only (nxdog9)")
    }

    @Test func aNarrowSelectedTabIsFaviconAndXWithoutHover() {
        let v = resolve(t.minActiveTabWidth, selected: true)
        #expect(v.showsClose && v.showsIcon && !v.showsTitle)
    }

    @Test func aWideSelectedTabKeepsItsXHoverOnly() {
        #expect(!resolve(t.maxTabWidth, selected: true).showsClose)
        #expect(resolve(t.maxTabWidth, selected: true, hovered: true).showsClose)
    }

    @Test func theSmallestSelectedTabIsItsCenteredX() {
        let v = resolve(t.minInactiveTabWidth, selected: true)
        #expect(v.showsClose && !v.showsIcon && !v.showsTitle && v.centersContent)
    }

    @Test func pinnedTabsStayIconOnly() {
        let v = resolve(t.pinnedTabWidth, selected: true, hovered: true, pinned: true)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
    }

    @Test func aCollapsingTabShowsNothing() {
        let v = resolve(t.minInactiveTabWidth / 2, selected: true, hovered: true)
        #expect(!v.showsIcon && !v.showsTitle && !v.showsClose)
    }
}

/// The strip wires Chrome's separator rule (TabSeparatorVisibility) into
/// its cells: the selected and the hovered tab hide the separators on both
/// sides, the line before + follows the last tab, and hover applies at once.
@MainActor @Suite struct TabSeparatorTests {
    private func makeStrip(_ tabs: [TabItem], selected: String) -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: tabs, selectedID: TabID(selected))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 400, height: TabStripView.preferredHeight)
        window.contentView!.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)
        return (strip, window)
    }

    @Test func selectedAndHoveredTabsHideTheSeparatorsOnBothSides() {
        let tabs = (0..<6).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let (strip, window) = makeStrip(tabs, selected: "t2")
        defer { window.close() }
        func separators() -> [Bool] { (0..<6).map { strip.cells[TabID("t\($0)")]!.showsSeparator } }
        #expect(separators() == [true, false, false, true, true, true])
        strip.setHovered(TabID("t4"))
        #expect(separators() == [true, false, false, false, false, true])
        strip.setHovered(TabID("t5"))
        #expect(separators() == [true, false, false, true, false, false])
        strip.setHovered(nil)
        #expect(separators() == [true, false, false, true, true, true])
    }

    @Test func separatorsCrossThePinnedEdge() {
        let tabs = (0..<4).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)", isPinned: $0 < 2) }
        let (strip, window) = makeStrip(tabs, selected: "t0")
        defer { window.close() }
        #expect((0..<4).map { strip.cells[TabID("t\($0)")]!.showsSeparator } == [false, true, true, true])
    }
}
