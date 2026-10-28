import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A small pane's chrome gives way to its content (Lawrence 2026-10-28; handoff pane-min.md, repeat-runoff.md part
/// 2): under about 160 pt the tab strip is compact (the + goes, "…" holds what it offered), a pane shorter than its
/// strip and one terminal row hides the strip, and a pane thinner than one cell is a folded bar over hidden content.
/// Nothing overlaps.
@MainActor @Suite(.serialized) struct PaneSmallChromeTests {
    static func pane(width: CGFloat, height: CGFloat) -> PaneContentView {
        let pane = PaneContentView.testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("t1"), title: "zsh"), TabItem(id: TabID("t2"), title: "logs")]),
                                           reveal: LaunchReveal(deadline: .zero))
        pane.show(NSView())
        pane.frame = NSRect(x: 0, y: 0, width: width, height: height)
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    static func collapsedBar(in pane: PaneContentView) -> NSView? {
        pane.subviews.first { $0.accessibilityIdentifier() == "cmux.pane.collapsedBar" }
    }

    /// A roomy pane: strip, + and content as before, and no folded bar.
    @Test func aRoomyPaneKeepsItsChrome() {
        let pane = Self.pane(width: 600, height: 400)
        #expect(!pane.stripView.isHidden)
        #expect(!pane.stripView.newTabButton.isHidden)
        #expect(Self.collapsedBar(in: pane).map(\.isHidden) ?? true)
        #expect(!pane.contentHost.isHidden)
    }

    /// Under 160 pt the strip is compact: its + is gone (the pane's "…" offers what opens in it).
    @Test func aNarrowPaneHasACompactStrip() {
        let pane = Self.pane(width: 120, height: 400)
        #expect(!pane.stripView.isHidden)
        #expect(pane.stripView.newTabButton.isHidden, "the + leaves a 120 pt strip")
        #expect(pane.stripView.frame.maxX <= pane.bounds.maxX + 0.5)
    }

    /// Shorter than the strip and one row: the strip hides and the content takes the whole pane.
    @Test func aShortPaneHidesItsStrip() {
        let pane = Self.pane(width: 600, height: 30)
        #expect(pane.stripView.isHidden, "a 30 pt pane is one terminal row, no strip")
        #expect(abs(pane.contentHost.frame.height - 30) < 0.5, "the content has the pane: \(pane.contentHost.frame)")
        #expect(pane.paneHeaderHeight == 0)
    }

    /// Thinner than a cell: a folded bar covers the pane and the content behind it is hidden (a terminal keeps
    /// its grid and its process).
    @Test func aPaneThinnerThanACellIsAFoldedBar() throws {
        for size in [CGSize(width: 6, height: 400), CGSize(width: 600, height: 6)] {
            let pane = Self.pane(width: size.width, height: size.height)
            let bar = try #require(Self.collapsedBar(in: pane), "\(size): no folded bar")
            #expect(!bar.isHidden && bar.frame == pane.bounds, "\(size): \(bar.frame)")
            #expect(pane.stripView.isHidden, "\(size)")
            #expect(pane.contentHost.isHidden, "\(size)")
            #expect(bar.accessibilityRole() == .button, "\(size)")
        }
    }
}
