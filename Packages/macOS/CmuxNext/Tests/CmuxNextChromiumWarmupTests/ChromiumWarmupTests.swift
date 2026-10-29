import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import Foundation
import Testing

/// When the warm start skips, and that every step is an idle task: posted once
/// startup settled, never run in the turn that asked, each with a `maxDelay`; the steps that hold
/// the main thread wait for 750 ms with no input and for a slot that may run past its deadline. An
/// engine with no embedded runtime is unavailable, so nothing here maps or starts Chromium (the
/// runtime is process-wide); the steps run against a fake engine and a fake idle poster.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupTests {
    final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// The end of menu tracking: ``end()`` calls the live observation.
    final class MenuEnd {
        final class Token {}
        private(set) var observations = 0
        private var ended: (@MainActor () -> Void)?
        private weak var token: Token?

        func observe(_ ended: @escaping @MainActor () -> Void) -> AnyObject {
            observations += 1
            let token = Token()
            self.token = token
            self.ended = ended
            return token
        }

        /// The menu closed: calls the observation while its token lives.
        @MainActor func end() {
            guard token != nil else { return }
            ended?()
        }
    }

    let idle = FakeIdle()
    let menu = MenuEnd()
    let input = FakeInputTap()

    func warmup(engine: any ChromiumWarmupEngine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()),
                memory: ManualMemoryLevelRegistry = ManualMemoryLevelRegistry(),
                trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let menu = menu
        return ChromiumWarmup(engine: engine, idle: idle, input: input, memory: memory, isTrackingMenu: trackingMenu,
                              observeMenuEnd: { menu.observe($0) })
    }

    /// Starts `warmup` with Chromium not the default and runs its launch check, so only the steps
    /// a test asks for are queued after.
    func started(_ warmup: ChromiumWarmup, pagesPending: @escaping @MainActor () -> Bool = { false },
                 pagesSpare: @escaping @MainActor () -> Bool = { false }) {
        warmup.start(defaultIsChromium: { false }, pagesPending: pagesPending, pagesSpare: pagesSpare)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.launch"])
        idle.runPeriod()
    }

    /// The person's key `ago` before the fake's now.
    func key(_ ago: Duration) {
        let at = (idle.now - ago).components
        input.deliver(InputEventRecord(type: .keyDown, timestamp: Double(at.seconds) + Double(at.attoseconds) * 1e-18))
    }

    /// The delays the warmup asked for, each within a microsecond of `expected` (the key's time is
    /// a `Double` of seconds).
    func delays(are expected: [Duration]) -> Bool {
        idle.afters.count == expected.count
            && zip(idle.afters, expected).allSatisfy { abs(($0.delay - $1) / .microseconds(1)) < 1 }
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
        #expect(idle.posts.isEmpty, "no idle task")
    }

    /// While Chromium is the default engine: the launch check, CefInitialize and the first spare are
    /// three idle tasks, each posted by the one before, each with a `maxDelay` so a busy app still
    /// warms up as background work.
    @Test func launchInitializeAndSpareAreEachAnIdleTask() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        warmup.start(defaultIsChromium: { true })
        #expect(engine.preloads == 0, "start posts; nothing runs on its turn")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.launch"])
        #expect(idle.queued.first?.maxDelay == .seconds(5))

        idle.runPeriod()
        #expect(warmup.reason == .launch)
        #expect(engine.preloads == 1)
        await idle.posted(2)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.initialize"], "posted once the framework is mapped")
        #expect(idle.queued.first?.maxDelay == .seconds(5), "an app that never goes idle still starts Chromium")
        #expect(engine.initializes.isEmpty)

        idle.runPeriod()
        #expect(engine.initializes == ["launch"], "CefInitialize runs in the idle task's own turn, not a later one")
        #expect(engine.warmStarts.isEmpty, "the idle step awaits nothing")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        #expect(idle.queued.first?.maxDelay == .milliseconds(500), "the refill runs as background work past 500 ms")
        #expect(engine.prepared.isEmpty)

        idle.runPeriod()
        #expect(engine.prepared == [false])
        warmup.stop()
    }

    /// Nothing is posted while startup is not settled (the launch window, session restore): the
    /// launch check and a restored tab's CefInitialize wait for the settle.
    @Test func noStepRunsBeforeStartupSettles() async {
        idle.settled = false
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(engine.preloads == 1, "the framework maps off the main thread at once")
        await idle.held(2)
        #expect(idle.posts.isEmpty, "no idle task while launching")

        idle.settle()
        await idle.posted(2)
        #expect(Set(idle.queued.map(\.owner)) == ["ChromiumWarmup.launch", "ChromiumWarmup.initialize"])
        warmup.stop()
    }

    /// The take reports `onSpareWindowNeeded` in the key's turn (CEFSpareWindow.take): the refill is
    /// only posted then, and any number of reports before it runs make one idle task.
    @Test func refillReportsOnlyPostAndCoalesce() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        started(warmup)
        for _ in 0..<3 { engine.onSpareWindowNeeded?() }
        #expect(engine.prepared.isEmpty, "nothing is built in the turn that asked")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        idle.runPeriod()
        #expect(engine.prepared == [false])
        #expect(idle.queued.isEmpty)

        engine.onSpareWindowNeeded?()
        #expect(idle.queued.count == 1, "the next take posts the next refill")
        warmup.stop()
    }

    /// A key 60 ms before the idle period (a gap between two keys): no spare is built, and no idle
    /// task is posted again until one deadline at the end of the 750 ms quiet. A key during that
    /// wait makes the step wait again; once the person is quiet, the spare is built.
    @Test func inputLessThanTheQuietBeforeTheSlotBuildsNothing() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        started(warmup)
        engine.onSpareWindowNeeded?()
        key(.milliseconds(60))
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a spare was built 60 ms after a key")
        #expect(idle.queued.isEmpty, "nothing polls while the quiet runs")
        #expect(delays(are: [.milliseconds(690)]))
        #expect(idle.afters.first?.owner == "ChromiumWarmup.quiet")

        idle.now += .milliseconds(690)
        key(.milliseconds(100))
        idle.fireAfters()
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a key came during the wait")
        #expect(delays(are: [.milliseconds(650)]))

        idle.now += .milliseconds(651)
        idle.fireAfters()
        idle.runPeriod()
        #expect(engine.prepared == [false])
        warmup.stop()
    }

    /// The same quiet holds CefInitialize: a key 60 ms before the period starts no Chromium.
    @Test func inputLessThanTheQuietBeforeTheSlotStartsNoChromium() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        started(warmup)
        warmup.chromiumLikely(.newTabMenu)
        await idle.posted(2)
        key(.milliseconds(60))
        idle.runPeriod()
        #expect(engine.initializes.isEmpty, "CefInitialize ran 60 ms after a key")
        #expect(idle.afters.count == 1)
        warmup.stop()
    }

    /// A short period between frames cannot hold CefInitialize or a window build: the step is posted
    /// for the next slot with what is left of its `maxDelay`, and runs in a slot that may overrun.
    @Test func aShortPeriodPostsTheStepAgainWithItsMaxDelayLeft() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        started(warmup)
        engine.onSpareWindowNeeded?()
        idle.now += .milliseconds(200)
        idle.runPeriod(mayOverrun: false)
        #expect(engine.prepared.isEmpty, "a spare was built in a short period")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        #expect(idle.queued.first?.maxDelay == .milliseconds(300), "the post again keeps the first post's deadline")

        idle.now += .milliseconds(400)
        idle.runPeriod(mayOverrun: false)
        #expect(idle.queued.first?.maxDelay == .zero, "past its deadline: background work at once")
        idle.runPeriod()
        #expect(engine.prepared == [false])
        warmup.stop()
    }

    /// A spare window came up while the pages kind has none (`CEFSpareWindow.windowCameUp`
    /// reports `onSpareWindowNeeded`): an idle task, never the turn that asked, builds the next spare with
    /// the pages switch read then. Read again at each step: off, the step keeps no pages spare.
    @Test func eachSpareStepReadsThePagesSwitchWhenItRuns() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        started(warmup, pagesSpare: { pages.value })
        engine.onSpareWindowNeeded?()
        #expect(engine.prepared.isEmpty)
        idle.runPeriod()
        #expect(engine.prepared == [true], "the pages spare is built in the idle task")

        engine.onSpareWindowNeeded?()
        pages.value = false
        idle.runPeriod()
        #expect(engine.prepared == [true, false], "pages off when it ran: the step keeps no pages spare")
        warmup.stop()
    }

    /// `browser.defaultEngine` left Chromium, so pages no longer use it: the untaken
    /// pages spare closes at once; back on Chromium, an idle task builds it again. Before Chromium
    /// runs, nothing happens (the first spare step reads the switch itself).
    @Test func thePagesSpareFollowsTheSwitch() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        started(warmup, pagesSpare: { pages.value })

        engine.isRunning = false
        pages.value = false
        warmup.pagesSpareChanged()
        #expect(engine.droppedPages == 0 && idle.queued.isEmpty, "no Chromium yet, no spare to drop")

        engine.isRunning = true
        warmup.pagesSpareChanged()
        #expect(engine.droppedPages == 1, "pages left Chromium: the pages spare closes")
        #expect(idle.queued.isEmpty)

        pages.value = true
        warmup.pagesSpareChanged()
        #expect(engine.prepared.isEmpty, "not on the switch's turn")
        idle.runPeriod()
        #expect(engine.prepared == [true])
        #expect(engine.droppedPages == 1)
        warmup.stop()
    }

    /// Chrome's spare rule: a warning holds the spare windows (the untaken one
    /// stays) and no spare step is posted or runs; critical keeps the hold and closes
    /// the untaken one; back at normal the hold lets go and an idle task, never the level's turn,
    /// builds the spare again.
    @Test func noSpareWindowUnderPressureAndNoRefillUntilNormal() {
        let engine = FakeWarmupEngine()
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        #expect(memory.liveCount == 1, "the spare windows register once")
        #expect(engine.holds.isEmpty, "normal holds nothing")
        started(warmup)
        engine.onSpareWindowNeeded?()
        idle.runPeriod()
        #expect(engine.prepared == [false])

        memory.send(.warning)
        #expect(engine.holds == [true], "a warning holds the spares")
        #expect(engine.closes == 0, "a warning closed the untaken spare")
        #expect(engine.spareWindowCount == 1)
        engine.onSpareWindowNeeded?()
        #expect(idle.queued.isEmpty, "no spare step is posted at warning")
        idle.runPeriod()
        #expect(engine.prepared == [false], "no refill at warning")

        memory.send(.critical)
        #expect(engine.holds == [true, true], "critical keeps the hold")
        #expect(engine.closes == 1, "critical closes the untaken spare once")
        #expect(engine.spareWindowCount == 0)
        engine.onSpareWindowNeeded?()
        #expect(idle.queued.isEmpty, "no spare step is posted at critical")
        idle.runPeriod()
        #expect(engine.prepared == [false], "no refill at critical")

        memory.send(.normal)
        #expect(engine.holds.last == false, "normal lets the spares go")
        #expect(engine.prepared == [false], "nothing is built on the level's turn")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        idle.runPeriod()
        #expect(engine.prepared == [false, false], "an idle task builds the spare again")
        warmup.stop()
    }

    /// Pressure that comes while a spare step is queued, or waits for the input quiet, takes the step
    /// back in the level's turn with its quiet deadline (no wakeup for a spare that cannot be made);
    /// its idle task builds nothing.
    @Test func pressureTakesBackAWaitingSpareStep() {
        let engine = FakeWarmupEngine()
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        started(warmup)
        engine.onSpareWindowNeeded?()
        memory.send(.warning)
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a queued spare was built at warning")

        memory.send(.normal)
        key(.milliseconds(60))
        idle.runPeriod()
        #expect(idle.afters.count == 1, "the spare waits for the quiet")
        memory.send(.warning)
        #expect(idle.afters.allSatisfy { $0.token == nil }, "a warning ended the quiet wait")
        idle.fireAfters()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a spare was built at warning")
        warmup.stop()
    }

    /// Pressure takes back only a spare step: `CefInitialize` (`chromiumLikely`) builds no spare
    /// and still runs.
    @Test func pressureLeavesTheInitializeStep() async {
        let engine = FakeWarmupEngine(running: false)
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        started(warmup)
        warmup.chromiumLikely(.newTabMenu)
        await idle.posted(2)
        memory.send(.warning)
        #expect(warmup.pending == [.initialize], "a warning took back CefInitialize")
        idle.runPeriod()
        #expect(warmup.pending.isEmpty)
        memory.send(.normal)
        await idle.posted(3)
        #expect(engine.initializes == ["newTabMenu"])
        warmup.stop()
    }

    /// A step whose idle task comes while a menu tracks builds nothing and posts nothing more (no
    /// re-check on a timer or each period); the end of tracking posts it again.
    @Test func aStepDuringMenuTrackingWaitsForTheMenuToClose() {
        let engine = FakeWarmupEngine()
        let tracking = Flag(false)
        let warmup = warmup(engine: engine, trackingMenu: { tracking.value })
        started(warmup)
        tracking.value = true
        engine.onSpareWindowNeeded?()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a menu tracks")
        #expect(idle.queued.isEmpty, "nothing polls while it does")
        engine.onSpareWindowNeeded?()
        #expect(idle.queued.isEmpty, "the waiting step serves this report too")
        #expect(menu.observations == 1)

        tracking.value = false
        menu.end()
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        #expect(engine.prepared.isEmpty, "posted, not run, at the menu's end")
        menu.end()
        #expect(idle.queued.count == 1, "the observation ended with the menu")
        idle.runPeriod()
        #expect(engine.prepared == [false])
        warmup.stop()
    }

    /// A window drag or a live resize runs the main run loop in `eventTracking` mode with no menu
    /// (the app's `isTrackingMenu` reads NSMenu's notifications, so it is false then): the step
    /// waits for no menu end, and the next spare request still builds a spare.
    @Test func eventTrackingWithNoMenuNeverParksTheSpare() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        started(warmup)
        engine.onSpareWindowNeeded?()
        idle.runPeriod()
        #expect(engine.prepared == [false])
        #expect(menu.observations == 0, "no wait for a menu end that never comes")
        engine.onSpareWindowNeeded?()
        idle.runPeriod()
        #expect(engine.prepared == [false, false], "the next request still builds a spare")
        warmup.stop()
    }

    /// A page being made builds its own window: the spare step waits for the pages to settle, and
    /// reports meanwhile post nothing.
    @Test func aPageBeingMadeHoldsTheSpareUntilThePagesSettle() {
        let engine = FakeWarmupEngine()
        let making = Flag(true)
        let warmup = warmup(engine: engine)
        started(warmup, pagesPending: { making.value })
        engine.onSpareWindowNeeded?()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty)
        engine.onSpareWindowNeeded?()
        #expect(idle.queued.isEmpty, "the spare waits for the pages, not for a report")

        making.value = false
        warmup.pagesSettled()
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        idle.runPeriod()
        #expect(engine.prepared == [false])
        warmup.stop()
    }

    @Test func stopEndsThePostedSteps() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        started(warmup)
        engine.onSpareWindowNeeded?()
        warmup.stop()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty)
        engine.onSpareWindowNeeded?()
        #expect(idle.queued.isEmpty)
    }

    /// The idle `CefInitialize` step runs Chromium's start in the slot it was given
    /// (`initializeLoaded`, no await), so the start lands in the idle period the scheduler picked
    /// after the input quiet, and the spare step is posted from that same turn.
    @Test func theIdleInitializeStepStartsChromiumInItsOwnTurn() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        started(warmup)
        warmup.chromiumLikely(.palette)
        await idle.posted(2)
        #expect(engine.initializes.isEmpty, "nothing starts before the idle task runs")
        idle.runPeriod()
        #expect(engine.initializes == ["palette"])
        #expect(engine.isRunning)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"], "the spare is posted from the same turn")
        warmup.stop()
    }

    @Test func theDefaultPolicy() {
        let policy = ChromiumWarmup.Policy()
        #expect(policy.recentUse == 7 * 24 * 60 * 60)
        #expect(policy.inputQuiet == .milliseconds(750))
        #expect(policy.warmStartMaxDelay == .seconds(5))
        #expect(policy.spareMaxDelay == .milliseconds(500))
    }
}

/// The idle poster: records each step and runs them in ``runPeriod(mayOverrun:)``, holds posts
/// until ``settle()`` while not ``settled``, and records each delay for ``fireAfters()``.
@MainActor final class FakeIdle: ChromiumWarmupIdle {
    struct Post {
        let owner: String
        let maxDelay: Duration
        let body: @MainActor (ChromiumWarmupSlot) -> Void
    }

    struct After {
        let delay: Duration
        let owner: String
        let action: @MainActor () -> Void
        weak var token: AnyObject?
    }

    final class Token {}

    var now: Duration = .seconds(100)
    var uptime: Duration { now }
    var settled = true
    private(set) var posts: [Post] = []
    private(set) var afters: [After] = []
    private var ran = 0
    private var held: [@MainActor () -> Void] = []
    private var postWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Posted and not run yet.
    var queued: [Post] { Array(posts[ran...]) }

    func postIdleStep(owner: String, maxDelay: Duration, file: StaticString, line: UInt,
                      _ body: @escaping @MainActor (ChromiumWarmupSlot) -> Void) {
        posts.append(Post(owner: owner, maxDelay: maxDelay, body: body))
        let ready = postWaiters.filter { $0.count <= posts.count }
        postWaiters.removeAll { $0.count <= posts.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func whenStartupSettled(_ action: @escaping @MainActor () -> Void) {
        guard settled else {
            held.append(action)
            let ready = heldWaiters.filter { $0.count <= held.count }
            heldWaiters.removeAll { $0.count <= held.count }
            for waiter in ready {
                waiter.continuation.resume()
            }
            return
        }
        action()
    }

    func after(_ delay: Duration, owner: String, _ action: @escaping @MainActor () -> Void) -> AnyObject {
        let token = Token()
        afters.append(After(delay: delay, owner: owner, action: action, token: token))
        return token
    }

    /// Startup settled: the held posts go on, in order.
    func settle() {
        settled = true
        let actions = held
        held = []
        for action in actions {
            action()
        }
    }

    /// Returns once `count` steps were posted in all (the warmup's tasks posted them).
    func posted(_ count: Int) async {
        guard posts.count < count else { return }
        await withCheckedContinuation { postWaiters.append((count, $0)) }
    }

    /// Returns once `count` steps are held for the settle.
    func held(_ count: Int) async {
        guard held.count < count else { return }
        await withCheckedContinuation { heldWaiters.append((count, $0)) }
    }

    /// The delays end: each whose token lives runs.
    func fireAfters() {
        let due = afters
        afters = []
        for after in due where after.token != nil {
            after.action()
        }
    }

    /// One idle period: runs the steps posted before it; a step posted meanwhile waits for the next.
    func runPeriod(mayOverrun: Bool = true) {
        let due = queued
        ran = posts.count
        for post in due {
            post.body(ChromiumWarmupSlot(mayOverrun: mayOverrun))
        }
    }
}

/// Records the warmup's steps; runs nothing.
@MainActor final class FakeWarmupEngine: ChromiumWarmupEngine {
    var availability: BrowserEngineAvailability = .available
    var isRunning: Bool
    /// The `pages` argument of each `prepareSpareWindow` call.
    private(set) var prepared: [Bool] = []
    private(set) var droppedPages = 0
    /// The argument of each `holdSpareWindows` call.
    private(set) var holds: [Bool] = []
    /// How many times the untaken spares were closed (`closeUntakenSpareWindows`).
    private(set) var closes = 0
    private(set) var spareWindowCount = 0
    private(set) var preloads = 0
    /// The reason of each `warmStart` (the host's launch start, which awaits the load).
    private(set) var warmStarts: [String] = []
    /// The reason of each `initializeLoaded` (the idle step's start, on its own turn).
    private(set) var initializes: [String] = []
    var onSpareWindowNeeded: (@MainActor () -> Void)?

    init(running: Bool = true) {
        isRunning = running
    }

    func usedRecently(within window: TimeInterval) async -> Bool { false }
    func preload() { preloads += 1 }
    func libraryLoadEnded() async {}

    func warmStart(reason: String) async {
        warmStarts.append(reason)
        isRunning = true
    }

    func initializeLoaded(reason: String) -> Bool {
        initializes.append(reason)
        isRunning = true
        return true
    }

    func prepareSpareWindow(pages: Bool) -> Bool {
        prepared.append(pages)
        spareWindowCount = 1
        return true
    }

    func dropPagesSpareWindow() { droppedPages += 1 }

    func holdSpareWindows(_ held: Bool) {
        holds.append(held)
    }

    func closeUntakenSpareWindows() {
        closes += 1
        spareWindowCount = 0
    }
}
