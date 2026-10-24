import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A busy tab re-checks its spinner when its strip asks (`TabStripView+StatusIndicators`): the strip
/// asks only while it shows, so a parked workspace's busy tab costs nothing on a Cmd-Tab
/// (TabStripIndicatorResyncTests covers the strip's side).
@MainActor @Suite(.serialized) struct TabCellActivationCostTests {
    private func busyCell() -> TabCell {
        var item = TabItem(id: TabID("busy"), title: "Agent")
        item.indicator = .working
        return TabCell(item: item)
    }

    @Test func aBusyTabResyncsWhenItsStripAsks() {
        let cell = busyCell()
        #expect(cell.showsStatusIndicator)
        let before = StatusIndicatorAppearance.resyncs
        cell.statusIndicatorResync()
        #expect(StatusIndicatorAppearance.resyncs == before + 1)
    }

    @Test func anIdleTabIsNoIndicatorHost() {
        let cell = TabCell(item: TabItem(id: TabID("idle"), title: "Shell"))
        #expect(!cell.showsStatusIndicator)
    }
}
