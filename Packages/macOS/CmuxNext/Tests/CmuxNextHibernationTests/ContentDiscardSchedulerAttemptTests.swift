import CmuxNextCompat
import CmuxNextHibernation
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
        // The preparation is a task: it starts after this turn. Its first call runs through to its replan
        // (the fake's preparation never suspends), which starts the next one as a task too.
        var preparations = host.preparations.makeAsyncIterator()
        #expect(await preparations.next() == "a")
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
    /// Each key whose preparation began, in order: a test awaits the start of a preparation task here.
    let preparations: AsyncStream<String>
    private let preparation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: String.self)
        preparations = stream.stream
        preparation = stream.continuation
    }

    func discardPolicy(of key: String) -> ContentDiscardPolicy? { closed.contains(key) ? nil : .afterHidden(.zero) }
    func keepReasons(of key: String) -> [CannotDiscardReason] { [] }
    func isDrawn(_ key: String) -> Bool { false }
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        prepared.append(key)
        preparation.yield(key)
        return refuses.contains(key) ? nil : ContentViewState()
    }
    func commitDiscard(_ key: String) {
        discarded.append(key)
        scheduler?.noteDiscarded(key)
    }
}
