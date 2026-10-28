import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// p07-memory-104 for the newer kinds (page tabs, conversations, overlay pages): an item whose preparation comes back
/// empty while it stays hidden, or whose release lets nothing go, is `discardAttempted` until it shows (Chrome's
/// `DiscardAttemptMarker`, page_discarding_helper.cc), so the next due item takes its slot instead of the same item
/// being tried on every pass. Items due at once (a zero timeout) on the scheduler's one-per-pass proactive pace.
@MainActor @Suite struct ContentDiscardSchedulerAttemptTests {
    private func makeScheduler() -> (ContentDiscardScheduler, AttemptHost) {
        let host = AttemptHost()
        let scheduler = ContentDiscardScheduler(kind: .internalPage)
        scheduler.host = host
        host.scheduler = scheduler
        return (scheduler, host)
    }

    @Test func aFailedPreparationGivesTheSlotToTheNextItemUntilItShows() async {
        let (scheduler, host) = makeScheduler()
        host.refuses = ["a"]
        scheduler.contentDidHide("a")
        scheduler.contentDidHide("b")
        scheduler.replan()
        #expect(host.prepared == ["a"], "one per pass, the longest hidden first")

        await scheduler.settled()  // a came back empty: the replan in its turn prepares b
        await scheduler.settled()

        #expect(host.prepared == ["a", "b"], "the failed item was tried again instead of the next one")
        #expect(scheduler.discardAttempts.contains("a"))
        #expect(scheduler.exemptions["a"] == .discardAttempted)
        #expect(host.discarded == ["b"])

        scheduler.contentDidShow("a")
        #expect(!scheduler.discardAttempts.contains("a"), "showing the item did not clear its mark")
        host.refuses = []
        scheduler.contentDidHide("a")
        scheduler.replan()
        await scheduler.settled()
        #expect(host.prepared == ["a", "b", "a"], "once shown, it may go again")
        #expect(host.discarded == ["b", "a"])
    }

    @Test func aReleaseThatLetsNothingGoMarksTheItem() {
        let (scheduler, host) = makeScheduler()
        scheduler.contentDidHide("a")
        scheduler.noteDiscardFailed("a")
        #expect(scheduler.discardAttempts.contains("a"))
        scheduler.replan()
        #expect(host.prepared.isEmpty, "an item whose release failed was prepared again before it showed")
        #expect(scheduler.exemptions["a"] == .discardAttempted)
    }

    @Test func aClosedItemDropsItsMark() {
        let (scheduler, host) = makeScheduler()
        scheduler.contentDidHide("a")
        scheduler.noteDiscardFailed("a")
        host.closed = ["a"]
        scheduler.replan()
        #expect(!scheduler.discardAttempts.contains("a"))
        #expect(scheduler.exemptions["a"] == nil)
    }

    /// Page tabs follow `browser.hibernation` (trunk #25920: a page never reloads unless the person asks):
    /// with nothing written (`.fallback`) or with it off, a due hidden page tab is never prepared nor
    /// discarded, at any pressure (each pressure change and the critical release slice replan), and no
    /// deadline is armed.
    /// Writing the setting looks again after its turn and lets the page go.
    @Test func browserHibernationUnwrittenOrOffKeepsEveryPageTabAtAnyPressure() async {
        for (setting, kept) in [(BrowserHibernationSetting.fallback, CannotDiscardReason.keepsState),
                                (BrowserHibernationSetting(mode: .off), .disabled)] {
            let (scheduler, host) = makeScheduler()
            scheduler.update(browserHibernation: setting)
            scheduler.contentDidHide("a")
            #expect(!scheduler.hasDeadline, "\(kept): a hide armed a discard")
            for pressure in [MemoryPressureLevel.normal, .warning, .critical] {
                scheduler.update(pressure: pressure)
                scheduler.replan()
                await scheduler.settled()
                #expect(host.prepared.isEmpty, "\(kept) at \(pressure): a page tab was prepared for its discard")
                #expect(scheduler.exemptions["a"] == kept, "\(kept) at \(pressure)")
                #expect(!scheduler.hasDeadline, "\(kept) at \(pressure): a look was armed though only the setting lets it go")
            }
            #expect(host.discarded.isEmpty)

            scheduler.update(pressure: .normal)
            scheduler.update(browserHibernation: BrowserHibernationSetting(mode: .moderate))
            #expect(host.prepared.isEmpty, "the setting's change prepared a discard in its own turn")
            #expect(scheduler.nextCheck == 0, "writing browser.hibernation armed no look")
            scheduler.replan()
            await scheduler.settled()
            #expect(host.discarded == ["a"], "\(kept): writing browser.hibernation kept a due page tab")
        }
    }

    @Test func anItemThatIsNotHiddenIsNeverMarked() {
        let (scheduler, _) = makeScheduler()
        scheduler.noteDiscardFailed("a")
        #expect(!scheduler.discardAttempts.contains("a"))
    }
}

/// Items due as soon as they hide; the ones in `refuses` come back empty from their preparation.
@MainActor
private final class AttemptHost: ContentDiscardHost {
    weak var scheduler: ContentDiscardScheduler?
    var refuses: Set<String> = []
    var closed: Set<String> = []
    private(set) var prepared: [String] = []
    private(set) var discarded: [String] = []

    func discardPolicy(of key: String) -> ContentDiscardPolicy? { closed.contains(key) ? nil : .afterHidden(.zero) }
    func keepReasons(of key: String) -> [CannotDiscardReason] { [] }
    func isDrawn(_ key: String) -> Bool { false }
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        prepared.append(key)
        return refuses.contains(key) ? nil : ContentViewState()
    }
    func commitDiscard(_ key: String) {
        discarded.append(key)
        scheduler?.noteDiscarded(key)
    }
}
