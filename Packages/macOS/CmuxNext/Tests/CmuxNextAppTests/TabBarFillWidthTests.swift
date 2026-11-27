import AppKit
@testable import CmuxNextTabs
import CmuxNextDesign
import Testing

/// Leo, 2026-11-24: "do we never expand out tab widths? we do right? but this one isn't for soem reason? why half of the
/// space taken up by blank!?" The pane toolbar must give the tab strip back the room of buttons that fold at the toolbar's
/// half-pane cap: reserving its full capped intrinsic width left that half of the bar blank and squeezed the tabs.
@MainActor @Suite struct TabBarFillWidthTests {
    /// A 600 pt pane whose toolbar keeps room for more pins than fit half the pane: at the cap only "…" shows.
    @Test func cappedToolbarUsesItsFittedWidth() {
        let view = PaneToolbarView()
        let paneWidth: CGFloat = 600, cap = paneWidth / 2
        let pins = Int((cap / TitlebarBandButton.side).rounded(.up)) + 2
        view.show([], zoomed: true, reserving: pins)
        #expect(view.intrinsicContentSize.width > cap, "the reserved room exceeds the half-pane cap")

        // What layout() shows at the cap: the trailing gap and "…" alone.
        let shown = PaneToolbarView.trailingGap + TitlebarBandButton.side
        #expect(view.tabRowWidth(fitting: cap) == shown)
        #expect(view.paneWidth(in: paneWidth, sharing: false) == shown,
                "the strip gets the fitted toolbar width, not the half-pane cap")

        // Three tabs in the strip now take the freed room, up to their max width, instead of half the bar.
        let items = (0..<3).map { TabLayoutItem(id: TabID("t\($0)")) }
        let metrics = TabStripMetrics.standard
        let fitted = TabLayoutEngine.layout(items: items, availableWidth: paneWidth - view.paneWidth(in: paneWidth, sharing: false),
                                            style: .chrome, metrics: metrics)
        let halfBar = TabLayoutEngine.layout(items: items, availableWidth: paneWidth - cap, style: .chrome, metrics: metrics)
        for (tab, squeezed) in zip(fitted.slots, halfBar.slots) {
            #expect(tab.width <= metrics.maxTabWidth, "a tab never exceeds its max width")
            #expect(tab.width > squeezed.width || tab.width == metrics.maxTabWidth, "\(tab.width) vs \(squeezed.width)")
        }
    }

    /// Room kept for another tab's pins stays while it fits (a selection moves no tab).
    @Test func uncappedToolbarKeepsItsReservedRoom() {
        let view = PaneToolbarView()
        view.show([], zoomed: true, reserving: 3)
        #expect(view.paneWidth(in: 600, sharing: false) == view.intrinsicContentSize.width)
        #expect(view.intrinsicContentSize.width > view.tabRowWidth)
    }
}
