import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A busy tab in a parked workspace's strip costs nothing when the app comes back to the front
/// (user 2026-10-21, Cmd-Tab lag with many workspaces and tabs); it re-checks its spinner once
/// when its strip shows again. Driven through a real resync moment of the cell's own appearance,
/// so the resync set (who a moment reaches at all) is under test, not only the cell's check.
@MainActor @Suite(.serialized) struct TabCellActivationCostTests {
    private let appearance = StatusIndicatorAppearance(appCenter: NotificationCenter(), workspaceCenter: NotificationCenter())

    private func cell(busy: Bool) -> TabCell {
        TabCell(item: item(busy: busy), appearance: appearance)
    }

    private func item(busy: Bool) -> TabItem {
        var item = TabItem(id: TabID("agent"), title: "Agent")
        item.indicator = busy ? .working : .idle
        return item
    }

    /// How many cells `body`'s moments called (`visits`) and how many checked their indicator
    /// again (`checks`, catch-ups included).
    private func cost(_ body: () -> Void) -> (visits: UInt64, checks: UInt64) {
        let visits = appearance.resyncVisits, checks = appearance.resyncs
        body()
        return (appearance.resyncVisits - visits, appearance.resyncs - checks)
    }

    @Test func aHiddenStripsBusyTabIsNotReachedAndCatchesUpOnceWhenItShows() {
        let cell = cell(busy: true)
        cell.isStripShown = false
        let parked = cost {
            appearance.resync()
            appearance.resync()
        }
        #expect(parked.visits == 0, "a parked strip's tab was walked by an activation")
        #expect(parked.checks == 0, "a parked strip's tab did activation work")
        #expect(cost { cell.isStripShown = true }.checks == 1, "the owed resync runs once when the strip shows")
        #expect(cost {
            cell.isStripShown = false
            cell.isStripShown = true
        }.checks == 0)
        let shown = cost { appearance.resync() }
        #expect(shown.visits == 1, "a shown strip's busy tab is not reached by activations")
        #expect(shown.checks == 1)
    }

    @Test func aShownStripsBusyTabIsReachedAtOnce() {
        let cell = cell(busy: true)
        let shown = cost { appearance.resync() }
        #expect(shown.visits == 1)
        #expect(shown.checks == 1)
        withExtendedLifetime(cell) {}
    }

    /// An idle tab is not in the resync set; when it turns busy on a shown strip it draws a fresh
    /// spinner, so it owes nothing for the moments that passed while it was idle.
    @Test func aTabTurningBusyOnAShownStripOwesNoCatchUp() {
        let cell = cell(busy: false)
        #expect(cost { appearance.resync() }.visits == 0, "an idle tab was walked by an activation")
        cell.update(item: item(busy: true))
        #expect(cost {
            cell.isStripShown = false
            cell.isStripShown = true
        }.checks == 0, "a tab that turned busy on screen ran a catch-up for a moment it never missed")
        #expect(cost { appearance.resync() }.visits == 1)
    }
}
