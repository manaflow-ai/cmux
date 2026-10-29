@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextHibernation
import Testing

/// A browser tab whose discard was tried and did not finish (its `beforeunload` asked, it had no
/// state to restore, the engine refused its freeze, its release found nothing prepared) carries Chrome's
/// `DiscardAttemptMarker` (page_discarding_helper.cc): the planner keeps it as `discardAttempted` from every discard
/// until it shows (discard_eligibility_policy.cc), and the replan gives its slot to the next due tab at once. A probe
/// answer that keeps the page (a child frame's `beforeunload`) is no failed discard. Mock tabs on the urgent pass's
/// rig, no pressure (moderate: 30 minutes, two per pass).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHibernationDiscardAttemptTests {
    typealias Rig = BrowserHibernationUrgentPassTests.Rig

    /// Past the moderate 30 minutes with the one show's focus credit (300 s): every tab is due.
    static let due: Double = 2_400

    @Test func aFailedDiscardGivesItsSlotToTheNextDueTab() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        hide(rig, ["a", "b", "c"])
        rig.advance(seconds: Self.due)
        #expect(rig.hibernation.probing.isEmpty)

        rig.hibernation.discardFailed("a", .beforeUnload)

        #expect(rig.hibernation.discardAttempts.contains("a"))
        #expect(rig.hibernation.exemptions["a"] == .discardAttempted)
        #expect(rig.hibernation.probing == ["b", "c"], "the failed tab kept its slot instead of the next due tabs")
    }

    @Test func theMarkLastsUntilTheTabShows() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        hide(rig, ["a", "control"])
        rig.hibernation.discardFailed("a", .unsupported)
        rig.advance(seconds: Self.due)
        rig.hibernation.replan()
        #expect(rig.hibernation.probing == ["control"], "a tab whose discard failed was tried again before it showed")
        #expect(rig.hibernation.exemptions["a"] == .discardAttempted)

        rig.services.cache.present("a", by: rig.pane, presence: .visible)

        #expect(!rig.hibernation.discardAttempts.contains("a"), "showing the tab did not clear its mark")
        #expect(rig.hibernation.exemptions["a"] == nil)
    }

    /// The mark keeps the tab from every discard, the person's Hibernate Tab too (Chrome's `kDiscardAttempted` is
    /// disallowed for every reason); it says why.
    @Test func hibernateTabRefusesAMarkedTab() {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        hide(rig, ["a"])
        rig.hibernation.discardFailed("a", .beforeUnload)

        #expect(rig.hibernation.hibernateNow("a") == .discardAttempted)
        #expect(rig.hibernation.discardAttempts.contains("a"))
        #expect(rig.hibernation.probing.isEmpty)
    }

    // MARK: The discard probe's own failures

    /// The page had no state to restore when its probe ended: marked, and the next due tab took the slot.
    @Test func aPageWithNoRestoreStateIsMarkedAndTheNextDueTabGoes() async throws {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        let tabs = hide(rig, ["a", "b", "c"])
        rig.advance(seconds: Self.due)
        rig.hibernation.replan()
        #expect(rig.hibernation.probing == ["a", "b"])
        // Their history goes while the probe runs.
        tabs["a"]?.hibernationRestore = nil
        tabs["b"]?.hibernationRestore = nil

        try await BrowserHibernationFrozenGrowthTests.until("the probes of a and b ended") {
            !rig.hibernation.probing.contains("a") && !rig.hibernation.probing.contains("b")
        }

        #expect(rig.hibernation.discardAttempts.contains("a"), "a page with no restore state was not marked")
        #expect(rig.hibernation.discardAttempts.contains("b"))
        #expect(tookTheSlot(rig, "c"), "the next due tab did not take the failed tabs' slot")
    }

    /// The page's beforeunload handlers asked (here they could not be asked: the same answer): marked, and the next
    /// due tab took the slot. The handlers never run again while it stays hidden.
    @Test func aPageWhoseBeforeUnloadAsksIsMarkedAndTheNextDueTabGoes() async throws {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        let tabs = hide(rig, ["a", "b", "c"], handler: ["a", "b"])
        rig.advance(seconds: Self.due)
        rig.hibernation.replan()
        #expect(rig.hibernation.probing == ["a", "b"])

        try await BrowserHibernationFrozenGrowthTests.until("the probes of a and b ended") {
            !rig.hibernation.probing.contains("a") && !rig.hibernation.probing.contains("b")
        }

        #expect(rig.hibernation.discardAttempts.contains("a"), "a page whose beforeunload asked was not marked")
        #expect(rig.hibernation.exemptions["a"] == .discardAttempted)
        #expect(tookTheSlot(rig, "c"), "the next due tab did not take the failed tabs' slot")
        rig.hibernation.replan()
        #expect(!rig.hibernation.probing.contains("a"), "a marked page was probed again")
        #expect(tabs["a"]?.commands.filter { $0 == .evaluate(BrowserPageBusy.askScript) }.count == 1)
    }

    /// A child frame's beforeunload is the probe's answer (the lead rule keeps the page), not a failed discard: no
    /// mark, and the page is asked again after the probe's backoff.
    @Test func aChildFrameBeforeUnloadKeepsThePageWithoutAMark() async throws {
        let rig = Rig(ranks: false)
        defer { rig.close() }
        hide(rig, ["a"], unload: ["a"])
        rig.advance(seconds: Self.due)
        rig.hibernation.replan()
        #expect(rig.hibernation.probing == ["a"])

        try await BrowserHibernationFrozenGrowthTests.until("the probe of a ended") { !rig.hibernation.probing.contains("a") }

        #expect(!rig.hibernation.discardAttempts.contains("a"), "a probe answer marked the page as a failed discard")
        #expect(rig.hibernation.exemptions["a"] == .beforeUnload)
    }

    // MARK: Helpers

    /// Hides mock tabs `keys`, 10 s apart (the first is the most idle), each answering the discard probe: a child
    /// frame's `beforeunload` for the keys in `unload`, a top-document handler for those in `handler`.
    @discardableResult
    private func hide(_ rig: Rig, _ keys: [String], unload: Set<String> = [], handler: Set<String> = []) -> [String: MockBrowserTab] {
        var tabs: [String: MockBrowserTab] = [:]
        for (index, key) in keys.enumerated() {
            if index > 0 { rig.advance(seconds: 10) }
            rig.hideTab(key)
            let tab = rig.services.cache.browsers[key]?.tab as? MockBrowserTab
            tab?.evaluationResult = .string(Self.answer(unload: unload.contains(key), handler: handler.contains(key)))
            tabs[key] = tab
        }
        return tabs
    }

    /// The field probe's and `pageBusy`'s answer in one JSON (the mock answers every script the same; the
    /// beforeunload ask then gets no Bool and counts as asking).
    private static func answer(unload: Bool, handler: Bool) -> String {
        """
        {"media":false,"form":false,"sound":false,"audio":false,"capturing":false,"unload":\(unload),"handler":\(handler),\
        "rtc":false,"device":false,"opaque":false}
        """
    }

    /// Tab `key`'s discard started: its probe runs or it hibernated already.
    private func tookTheSlot(_ rig: Rig, _ key: String) -> Bool {
        rig.hibernation.probing.contains(key) || rig.services.cache.lifecycle.phase(key) == .hibernated
    }
}
