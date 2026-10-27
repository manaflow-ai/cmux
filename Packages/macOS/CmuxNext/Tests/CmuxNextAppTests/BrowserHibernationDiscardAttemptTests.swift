@testable import CmuxNextApp
import CmuxNextHibernation
import Testing

/// p07-memory-104: a browser tab whose discard was tried and did not finish (its `beforeunload` asked, it had no
/// state to restore, the engine refused its freeze, its release found nothing prepared) carries Chrome's
/// `DiscardAttemptMarker` (page_discarding_helper.cc): the planner keeps it as `discardAttempted` until it shows,
/// and the replan gives its slot to the next due tab at once. Mock tabs on the urgent pass's rig, no pressure.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHibernationDiscardAttemptTests {
    typealias Rig = BrowserHibernationUrgentPassTests.Rig

    @Test func aFailedDiscardGivesItsSlotToTheNextDueTab() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        rig.hideTab("a")
        rig.advance(seconds: 10)
        rig.hideTab("b")
        rig.advance(seconds: 10)
        rig.hideTab("c")
        rig.advance(seconds: 2_000)  // every tab past the moderate 30 minutes; a hidden longest
        #expect(rig.hibernation.probing.isEmpty)

        rig.hibernation.discardFailed("a", .beforeUnload)

        #expect(rig.hibernation.discardAttempts.contains("a"))
        #expect(rig.hibernation.exemptions["a"] == .discardAttempted)
        #expect(rig.hibernation.probing == ["b", "c"], "the failed tab kept its slot instead of the next due tabs")
    }

    @Test func theMarkLastsUntilTheTabShows() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        rig.hideTab("a")
        rig.hibernation.discardFailed("a", .unsupported)
        rig.advance(seconds: 2_000)
        rig.hibernation.replan()
        #expect(rig.hibernation.probing.isEmpty, "a tab whose discard failed was tried again before it showed")
        #expect(rig.hibernation.exemptions["a"] == .discardAttempted)

        rig.services.cache.present("a", by: rig.pane, presence: .visible)

        #expect(!rig.hibernation.discardAttempts.contains("a"), "showing the tab did not clear its mark")
        #expect(rig.hibernation.exemptions["a"] == nil)
    }

    /// The mark stops cmux's own retries; the person's Hibernate Tab asks again and goes.
    @Test func hibernateTabTriesAMarkedTabAgain() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        rig.hideTab("a")
        rig.hibernation.discardFailed("a", .beforeUnload)

        #expect(rig.hibernation.hibernateNow("a") == nil)
        #expect(!rig.hibernation.discardAttempts.contains("a"))
        #expect(rig.hibernation.probing == ["a"])
    }
}
