import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInput
import Foundation
import Testing

/// When the warm start skips, and that every step is an idle task (p06-scheduler-050): posted,
/// never run in the turn that asked, the spare refill with a 500 ms `maxDelay`. An engine with no
/// embedded runtime is unavailable, so nothing here maps or starts Chromium (the runtime is
/// process-wide); the steps run against a fake engine and a fake idle poster.
@MainActor struct ChromiumWarmupTests {
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

    func warmup(engine: any ChromiumWarmupEngine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()),
                trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let menu = menu
        return ChromiumWarmup(engine: engine, idle: idle, isTrackingMenu: trackingMenu, observeMenuEnd: { menu.observe($0) })
    }

    /// Starts `warmup` with Chromium not the default and runs its launch check, so only the steps
    /// a test asks for are queued after.
    func started(_ warmup: ChromiumWarmup, pagesPending: @escaping @MainActor () -> Bool = { false },
                 pagesSpare: @escaping @MainActor () -> Bool = { false }) {
        warmup.start(defaultIsChromium: { false }, pagesPending: pagesPending, pagesSpare: pagesSpare)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.launch"])
        idle.runPeriod()
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
        #expect(idle.posts.isEmpty, "no idle task")
    }

    /// While Chromium is the default engine: the launch check, CefInitialize and the first spare are
    /// three idle tasks, each posted by the one before; only the spare refill has a `maxDelay`.
    @Test func launchInitializeAndSpareAreEachAnIdleTask() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        warmup.start(defaultIsChromium: { true })
        #expect(engine.preloads == 0, "start posts; nothing runs on its turn")
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.launch"])
        #expect(idle.queued.first?.maxDelay == nil)

        idle.runPeriod()
        #expect(warmup.reason == .launch)
        #expect(engine.preloads == 1)
        await settle { idle.queued.count == 1 }
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.initialize"], "posted once the framework is mapped")
        #expect(idle.queued.first?.maxDelay == nil)
        #expect(engine.warmStarts.isEmpty)

        idle.runPeriod()
        await settle { idle.queued.count == 1 }
        #expect(engine.warmStarts == ["launch"])
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.spare"])
        #expect(idle.queued.first?.maxDelay == .milliseconds(500), "the refill runs as background work past 500 ms")
        #expect(engine.prepared.isEmpty)

        idle.runPeriod()
        #expect(engine.prepared == [false])
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

    /// p13-webui-016: a spare window came up while the pages kind has none (`CEFSpareWindow.windowCameUp`
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

    /// p13-webui-016: `browser.defaultEngine` left Chromium, so pages no longer use it: the untaken
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

    @Test func theDefaultPolicy() {
        let policy = ChromiumWarmup.Policy()
        #expect(policy.recentUse == 7 * 24 * 60 * 60)
        #expect(policy.spareMaxDelay == .milliseconds(500))
    }

    /// Lets the warmup's tasks (the framework load, the warm start) finish: yields until `done`.
    private func settle(_ done: @MainActor () -> Bool) async {
        var turns = 0
        while !done(), turns < 1000 {
            turns += 1
            await Task.yield()
        }
    }
}

/// The idle poster: records each step and runs them in ``runPeriod()``.
@MainActor final class FakeIdle: ChromiumWarmupIdle {
    struct Post {
        let owner: String
        let maxDelay: Duration?
        let body: @MainActor () -> Void
    }

    private(set) var posts: [Post] = []
    private var ran = 0

    /// Posted and not run yet.
    var queued: [Post] { Array(posts[ran...]) }

    func postIdleStep(owner: String, maxDelay: Duration?, file: StaticString, line: UInt, _ body: @escaping @MainActor () -> Void) {
        posts.append(Post(owner: owner, maxDelay: maxDelay, body: body))
    }

    /// One idle period: runs the steps posted before it; a step posted meanwhile waits for the next.
    func runPeriod() {
        let due = queued
        ran = posts.count
        for post in due {
            post.body()
        }
    }
}

/// Records the warmup's steps; runs nothing.
@MainActor private final class FakeWarmupEngine: ChromiumWarmupEngine {
    var availability: BrowserEngineAvailability = .available
    var isRunning: Bool
    /// The `pages` argument of each `prepareSpareWindow` call.
    private(set) var prepared: [Bool] = []
    private(set) var droppedPages = 0
    private(set) var preloads = 0
    private(set) var warmStarts: [String] = []
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

    func prepareSpareWindow(pages: Bool) -> Bool {
        prepared.append(pages)
        return true
    }

    func dropPagesSpareWindow() { droppedPages += 1 }
}
