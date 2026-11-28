import AppKit
@testable import CmuxNextTabs
import Testing

/// Leo 2026-11-24: "do we never expand out tab widths? we do right? but this one isn't for soem
/// reason? why half of the space taken up by blank!?" After a mouse close the tabs keep their widths
/// until the pointer leaves the strip (Chrome's closing mode). The watch that ends the mode started
/// only on the strip's exit event, so a missed exit left three narrow tabs and an empty half bar.
/// The mode is watched from the close itself.
@MainActor @Suite(.serialized) struct TabClosingModeWatchedFromCloseTests {
    private func strip(count: Int) -> (TabStripView, TabStripModel) {
        let model = TabStripModel(tabs: (0..<count).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") },
                                  selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        strip.layoutSubtreeIfNeeded()
        model.intentHandler = { [unowned model] intent in
            if case .close(let id, _) = intent { model.tabs.removeAll { $0.id == id } }
        }
        return (strip, model)
    }

    @Test func aMouseCloseIsWatchedWithNoExitEvent() {
        let (strip, _) = strip(count: 12)
        strip.close(TabID("tab11"), source: .mouse)
        #expect(strip.closingModeWidth != nil, "a mouse close holds the tabs' widths")
        #expect(strip.closingWatch.isWatching, "and something is watching for the pointer to leave, with no exit event sent")
        strip.closingWatch.exit()
        #expect(strip.closingModeWidth == nil, "the watch's exit gives the tabs the whole bar again")
        #expect(!strip.closingWatch.isWatching)
    }

    @Test func aKeyboardCloseHoldsNothing() {
        let (strip, _) = strip(count: 12)
        strip.close(TabID("tab11"), source: .contextMenu)
        #expect(strip.closingModeWidth == nil)
        #expect(!strip.closingWatch.isWatching)
    }
}
