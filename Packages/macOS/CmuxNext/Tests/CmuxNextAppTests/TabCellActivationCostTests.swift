import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A busy tab in a parked workspace's strip costs nothing when the app comes back to the front
/// (user 2026-10-21, Cmd-Tab lag with many workspaces and tabs); it re-checks its spinner once
/// when its strip shows again.
@MainActor @Suite(.serialized) struct TabCellActivationCostTests {
    private func busyCell() -> TabCell {
        var item = TabItem(id: TabID("busy"), title: "Agent")
        item.indicator = .working
        return TabCell(item: item)
    }

    @Test func aHiddenStripsBusyTabWaitsUntilItShows() {
        let cell = busyCell()
        cell.isStripShown = false
        let before = StatusIndicatorAppearance.resyncs
        cell.statusIndicatorResync()
        cell.statusIndicatorResync()
        #expect(StatusIndicatorAppearance.resyncs == before, "a parked strip's tab did activation work")
        cell.isStripShown = true
        #expect(StatusIndicatorAppearance.resyncs == before + 1, "the owed resync runs once when the strip shows")
        cell.isStripShown = false
        cell.isStripShown = true
        #expect(StatusIndicatorAppearance.resyncs == before + 1)
    }

    @Test func aShownStripsBusyTabResyncsAtOnce() {
        let cell = busyCell()
        let before = StatusIndicatorAppearance.resyncs
        cell.statusIndicatorResync()
        #expect(StatusIndicatorAppearance.resyncs == before + 1)
    }
}
