@testable import CmuxNextDaemon
import Testing

/// A pane's waiting select (``PendingTabSelect``): its apply takes it once its tabs list it, and the daemon's pane that
/// takes Cmd-N's stand-in over takes over what the stand-in waited to select or showed selected, as one value (P0
/// STATUS 13438: the daemon's pane started on its New Tab page under the person's selected terminal).
@MainActor
@Suite struct PendingTabSelectTests {
    private func tab(_ surface: UInt64) -> TabModel { TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface))) }

    @Test func aCreatedTabIsTakenOnceTheShownTabsListIt() {
        let made = tab(7), other = tab(8)
        var select = PendingTabSelect(surface: made.surface)
        #expect(select.take(shown: [other], record: [other, made]) == nil, "taken before the shown tabs listed it")
        #expect(select.surface == made.surface, "a select not yet listed stopped waiting")
        #expect(select.take(shown: [other, made], record: [other, made]) == made.id)
        #expect(select.surface == nil, "a taken select still waits")
    }

    @Test func aReopenedTabIsTakenOnceTheRecordListsIt() {
        let reopened = tab(9)
        var select = PendingTabSelect(tab: reopened.id)
        #expect(select.take(shown: [], record: []) == nil)
        #expect(select.take(shown: [], record: [reopened]) == reopened.id, "the record lists it; the shown tabs need not")
        #expect(select.tab == nil)
    }

    /// The order a pane's apply has always taken them: the created tab first; a tab select waits while it is taken.
    @Test func theCreatedTabGoesBeforeTheReopenedOne() {
        let made = tab(7), reopened = tab(9)
        var select = PendingTabSelect(surface: made.surface, tab: reopened.id)
        #expect(select.take(shown: [made, reopened], record: [made, reopened]) == made.id)
        #expect(select.tab == reopened.id, "taking the created tab dropped the reopened one")
        #expect(select.take(shown: [made, reopened], record: [made, reopened]) == reopened.id)
    }

    @Test func theHandOverTakesTheStandInsWaitingSurfaceAlone() {
        var select = PendingTabSelect()
        select.takeOver(PendingTabSelect(surface: SurfaceID(rawValue: 7), tab: "tab_reopened"), selected: "pending_tab_a") { _ in "tab_daemon" }
        #expect(select.surface == SurfaceID(rawValue: 7))
        #expect(select.tab == nil, "a second waiting select went over: a later apply would select it")
    }

    @Test func theHandOverTakesTheStandInsWaitingTabBeforeItsSelection() {
        var select = PendingTabSelect()
        select.takeOver(PendingTabSelect(tab: "tab_reopened"), selected: "pending_tab_a") { _ in "tab_daemon" }
        #expect(select.surface == nil)
        #expect(select.tab == "tab_reopened")
    }

    /// The P0's order: the Ctrl-`'s stand-in terminal, already listed and selected on the stand-in, waits for nothing.
    @Test func theHandOverTakesTheStandInsSelectedTabAsTheDaemonsTabInItsPlace() {
        var replaced = PendingTabSelect(), kept = PendingTabSelect()
        replaced.takeOver(PendingTabSelect(), selected: "pending_tab_a") { $0 == "pending_tab_a" ? "tab_daemon" : nil }
        #expect(replaced.tab == "tab_daemon", "the daemon's tab in the stand-in's place was not taken")
        kept.takeOver(PendingTabSelect(), selected: "pending_tab_a") { _ in nil }
        #expect(kept.tab == "pending_tab_a", "the stand-in tab, still in its place, was not taken")
        #expect(replaced.surface == nil && kept.surface == nil)
    }

    @Test func aHandOverOfNothingChangesNothing() {
        var select = PendingTabSelect(surface: SurfaceID(rawValue: 3))
        select.takeOver(PendingTabSelect(), selected: nil) { _ in "tab_daemon" }
        #expect(select.surface == SurfaceID(rawValue: 3) && select.tab == nil)
    }
}
