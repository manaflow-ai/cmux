import AppKit
import CmuxNextCompat
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// VSyncHub: each display's only link lives on that display's vsync thread,
/// off-main subscribers tick there, and the main frame clock gets one coalesced post per vsync
/// (Chrome's `ui/display/mac/display_link_mac.mm`). The links are fakes; the hub threads are real.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VSyncHubTests {
    /// An off-main subscriber's callback runs on the display's hub thread, never on main, and the
    /// link was added to that thread's run loop.
    @Test func offMainCallbacksRunOnTheDisplayThreadNeverOnMain() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let seen = CallbackLog()
        let surface = hub.subscribe(to: 7, owner: "surface", armed: true) { tick in
            seen.record(tick: tick)
            return .more
        }
        #expect(surface != nil)

        try await links.fire(hub, display: 7, timestamp: 1, targetTimestamp: 1 + 1.0 / 120)
        try await links.fire(hub, display: 7, timestamp: 1 + 1.0 / 120, targetTimestamp: 1 + 2.0 / 120)

        let calls = seen.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { !$0.onMain }, "a vsync callback ran on the main thread")
        #expect(calls.allSatisfy { $0.thread == "cmux-next vsync 7" })
        #expect(calls.map(\.sequence) == [1, 2])
        let link = try #require(links.made.first)
        #expect(link.attachedThread == "cmux-next vsync 7", "the link must tick on the hub thread's run loop")
        #expect(!link.attachedOnMain)
    }

    /// No subscriber: no link. Subscribed but not armed: the link is paused (no wake) and does not
    /// count as live. A tick that returns `.done` disarms and pauses; the last subscriber leaving
    /// drops the link.
    @Test func zeroArmedSubscribersMeansNoWakeAndNoSubscriberMeansNoLink() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        #expect(hub.liveLinks == 0)
        #expect(links.made.isEmpty)

        let seen = CallbackLog()
        let surface = try #require(hub.subscribe(to: 1, owner: "surface") { tick in
            seen.record(tick: tick)
            return .done
        })
        await hub.onHubThread(1) {}
        let link = try #require(links.made.first)
        #expect(hub.liveLinks == 0, "no subscriber is armed: no live link")
        #expect(hub.pausedLinks == 1)
        #expect(link.isPaused, "no subscriber is armed: the link must not wake the thread")

        try await links.fire(hub, display: 1, timestamp: 1, targetTimestamp: 1.01)
        #expect(seen.calls.isEmpty, "a disarmed subscriber ticked")

        surface.arm()
        await hub.onHubThread(1) {}
        #expect(!link.isPaused)
        #expect(hub.armedSubscribers(on: 1) == 1)
        #expect(hub.liveLinks == 1)

        try await links.fire(hub, display: 1, timestamp: 2, targetTimestamp: 2.01)
        #expect(seen.calls.count == 1)
        #expect(hub.armedSubscribers(on: 1) == 0, "an empty tick disarms")
        #expect(link.isPaused, "nothing armed after the tick: the link pauses")
        #expect(hub.liveLinks == 0)

        surface.cancel()
        await hub.onHubThread(1) {}
        #expect(hub.liveLinks == 0 && hub.pausedLinks == 0)
        #expect(link.invalidated, "the last subscriber leaving drops the link")
        #expect(links.made.count == 1)
    }

    /// An arm that comes while the subscriber's tick runs wins over that tick's `.done`.
    @Test func anArmDuringATickKeepsTheSubscriberArmed() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let slot = SubscriptionSlot()
        let subscription = try #require(hub.subscribe(to: 1, owner: "surface", armed: true) { _ in
            slot.subscription?.arm() // the content changed again while it drew
            return .done
        })
        slot.subscription = subscription

        try await links.fire(hub, display: 1, timestamp: 1, targetTimestamp: 1.01)

        #expect(hub.armedSubscribers(on: 1) == 1)
        let link = try #require(links.made.first)
        #expect(!link.isPaused, "an arm during the tick keeps the link running")
        subscription.cancel()
    }

    /// The main frame clock and an off-main producer on one display share one link. Three vsyncs
    /// before main takes one are one main post, and main ticks once with the newest.
    @Test func mainAndOffMainSubscribersShareOneLinkAndMainGetsOneCoalescedTick() async throws {
        let links = FakeVSyncLinks()
        let posts = MainPosts()
        let hub = VSyncHub(makeLink: links.make, postToMain: posts.post)
        defer { hub.stopThreads() }
        let displays = DisplayClock(hub: hub, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "window", host: .screen, displays: displays, budget: nil)
        var mainTicks: [CFTimeInterval] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in
            mainTicks.append(tick.timestamp)
            return false
        }
        let offMain = CallbackLog()
        let surface = try #require(hub.subscribe(to: 1, owner: "surface", armed: true) { tick in
            offMain.record(tick: tick)
            return .more
        })
        client.activate()

        #expect(hub.linksMade == 1, "one link for the main clock and the producer")
        #expect(links.made.count == 1)
        #expect(hub.liveLinks == 1)
        #expect(displays.liveLinks == 1)
        let link = try #require(links.made.first)

        for frame in 1...3 {
            let timestamp = 10 + Double(frame) / 120
            try await links.fire(hub, display: 1, timestamp: timestamp, targetTimestamp: timestamp + 1.0 / 120)
        }
        #expect(offMain.calls.count == 3, "the producer ticks at every vsync")
        #expect(posts.count == 1, "at most one main post is pending")

        posts.drain()
        let newestVsync: CFTimeInterval = 10 + 3.0 / 120
        #expect(mainTicks == [newestVsync], "main ticks once, with the newest vsync")
        #expect(hub.mainHop.count == 1)

        // The client went idle on its tick: the clock left the hub, the producer keeps the link.
        #expect(displays.liveLinks == 0)
        await hub.onHubThread(1) {}
        #expect(hub.liveLinks == 1)
        #expect(!link.invalidated)

        surface.cancel()
        await hub.onHubThread(1) {}
        #expect(hub.liveLinks == 0)
        #expect(link.invalidated)
    }

    /// The main link arms while unpaused and disarms while paused (``DisplayClock`` pauses it when
    /// only windows nobody can see are left); invalidating it leaves the hub.
    @Test func pausingTheMainLinkDisarmsItAndInvalidatingItLeaves() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let link = try #require(hub.mainLink(display: 1) { _ in })
        await hub.onHubThread(1) {}
        let fake = try #require(links.made.first)
        #expect(hub.armedSubscribers(on: 1) == 1)
        #expect(!fake.isPaused)

        link.isPaused = true
        await hub.onHubThread(1) {}
        #expect(hub.armedSubscribers(on: 1) == 0)
        #expect(fake.isPaused)

        link.isPaused = false
        await hub.onHubThread(1) {}
        #expect(!fake.isPaused)

        link.invalidate()
        await hub.onHubThread(1) {}
        #expect(hub.liveLinks == 0)
        #expect(fake.invalidated)
    }

    /// The hop meter measures from the hub thread's post to main taking the tick.
    @Test func theMainHopIsMeasuredFromThePostToMainTakingTheTick() async throws {
        let links = FakeVSyncLinks()
        let posts = MainPosts()
        let media = SharedMediaTime()
        let hub = VSyncHub(makeLink: links.make, postToMain: posts.post, mediaTime: media.read)
        defer { hub.stopThreads() }
        var ticks = 0
        let link = try #require(hub.mainLink(display: 1) { _ in ticks += 1 })

        media.set(100)
        try await links.fire(hub, display: 1, timestamp: 100, targetTimestamp: 100.01)
        media.set(100.0002)
        posts.drain()

        #expect(ticks == 1)
        let p99 = try #require(hub.mainHop.percentile(0.99))
        #expect(abs(p99 - 0.0002) < 1e-9)
        link.invalidate()
    }

    /// A display with no screen gets no link, no subscription and no thread, however often it is
    /// asked: before, each try started a hub thread that never ended.
    @Test func aDisplayWithNoScreenGetsNoLinkAndNoThread() {
        let hub = VSyncHub(makeLink: { _, _ in nil }, postToMain: { _ in })
        defer { hub.stopThreads() }
        for _ in 0..<20 {
            #expect(hub.subscribe(to: 3, owner: "surface", armed: true) { _ in .more } == nil)
        }
        #expect(hub.liveLinks == 0)
        #expect(hub.linksMade == 0)
        #expect(hub.threadsStarted == 0, "a display with no link must not start a hub thread")
        #expect(hub.runningThreads == 0)
    }

    /// A frame clock on no screen (a headless launch, a closed lid with no external display) retries
    /// its link on every stall deadline; through the hub no retry starts a thread.
    @Test func aClockWithNoScreenStartsNoHubThreadOnItsStallRetries() {
        let factory = CountingNilFactory()
        let hub = VSyncHub(makeLink: factory.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let time = ClockTime()
        let displays = DisplayClock(hub: hub, displayOf: { _ in nil }, clock: ManualClock(), mediaTime: time.read)
        let scheduler = FrameScheduler(name: "headless", host: .screen, displays: displays, budget: nil)
        let client = FrameClient(owner: "daemon mirror", on: scheduler) { _ in true }
        client.activate()

        for _ in 0..<10 {
            time.now += 0.2
            displays.stallTimerFired(DisplayClock.noDisplay)
        }

        #expect(factory.calls >= 4, "the clock retries the link on its stall deadlines")
        #expect(hub.threadsStarted == 0)
        #expect(hub.runningThreads == 0)
        #expect(hub.linksMade == 0 && displays.liveLinks == 0)
        client.deactivate()
    }

    /// A stall rebuild through the hub rebuilds the display's shared link, so an off-main producer
    /// on the same display moves to the new link too (cancel and re-subscribe would keep the stuck one).
    @Test func aStallRebuildThroughTheHubRebuildsTheSharedLink() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let time = ClockTime()
        let displays = DisplayClock(hub: hub, displayOf: { _ in 1 }, clock: ManualClock(), mediaTime: time.read)
        let scheduler = FrameScheduler(name: "window", host: .screen, displays: displays, budget: nil)
        let client = FrameClient(owner: "spring", on: scheduler) { _ in true }
        let offMain = CallbackLog()
        let surface = try #require(hub.subscribe(to: 1, owner: "surface", armed: true) { tick in
            offMain.record(tick: tick)
            return .more
        })
        client.activate()
        #expect(links.made.count == 1)

        for _ in 0..<DisplayClock.stallsBeforeRebuild {
            time.now += 0.2
            displays.stallTimerFired(1)
        }
        await hub.onHubThread(1) {}

        #expect(links.made.count == 2, "the rebuild made a new link")
        #expect(hub.linksMade == 2)
        #expect(displays.linksMade == 2)
        let first = try #require(links.made.first)
        let second = try #require(links.made.last)
        #expect(first.invalidated, "the stuck link must go")
        #expect(!second.invalidated && !second.isPaused)
        #expect(second.attachedThread == "cmux-next vsync 1")
        #expect(hub.threadsStarted == 1, "the new link runs on the display's thread")
        try await links.fire(hub, display: 1, timestamp: 5, targetTimestamp: 5.01)
        #expect(offMain.calls.count == 1, "the producer ticks on the new link")

        client.deactivate()
        surface.cancel()
    }

    /// The link runs at the fastest rate an armed subscriber asked for: the main clock's 30 Hz alone,
    /// the display's full rate once a producer that asked for nothing arms beside it.
    @Test func theLinkRunsAtTheFastestRateAnArmedSubscriberAsksFor() async throws {
        let links = FakeVSyncLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let main = try #require(hub.mainLink(display: 1) { _ in })
        main.requestFrameRate(FrameRate.ambient.range)
        await hub.onHubThread(1) {}
        let link = try #require(links.made.first)
        #expect(link.requestedRates.last == 30)

        let surface = try #require(hub.subscribe(to: 1, owner: "surface", armed: true) { _ in .more })
        await hub.onHubThread(1) {}
        #expect(link.requestedRates.last == 120)

        surface.disarm()
        await hub.onHubThread(1) {}
        #expect(link.requestedRates.last == 30)
        surface.cancel()
        main.invalidate()
    }

    /// A hub thread stopped before its run loop ran ends (`CFRunLoopStop` on a run loop that is not
    /// running does nothing, so the thread would sleep forever).
    @Test func aHubThreadStoppedBeforeItsRunLoopRunsEnds() async {
        await withCheckedContinuation { (exited: CheckedContinuation<Void, Never>) in
            let thread = VSyncHub.HubThread(name: "cmux-next vsync test") { exited.resume() }
            #expect(thread.start())
            thread.stop()
        }
    }

    /// A hub thread stopped while its run loop runs ends after the blocks posted before the stop.
    @Test func aRunningHubThreadEndsOnStop() async {
        let ran = CallbackLog()
        await withCheckedContinuation { (exited: CheckedContinuation<Void, Never>) in
            let thread = VSyncHub.HubThread(name: "cmux-next vsync test") { exited.resume() }
            #expect(thread.start())
            thread.post { ran.record(tick: VSyncHub.Tick(display: 0, timestamp: 0, targetTimestamp: 0, sequence: 1)) }
            thread.stop()
            #expect(!thread.isRunning)
            #expect(!thread.start(), "a stopped thread never starts again")
        }
        #expect(ran.calls.count == 1)
    }
}

/// A link factory that finds no screen and counts how often it was asked.
@MainActor
private final class CountingNilFactory {
    private(set) var calls = 0

    var make: VSyncHub.LinkFactory {
        { [self] _, _ in
            calls += 1
            return nil
        }
    }
}

/// `CACurrentMediaTime` for a frame clock's stall checks.
@MainActor
private final class ClockTime {
    var now: CFTimeInterval = 1000
    var read: @MainActor () -> CFTimeInterval { { [self] in now } }
}

/// A display link whose vsyncs the test fires on the hub thread.
private final class FakeVSyncLink: VSyncLink, Sendable {
    let target: VSyncHub.LinkTarget
    private let state = Mutex(State())

    private struct State {
        var paused = false
        var invalidated = false
        var attachedThread: String?
        var attachedOnMain = false
        var requestedRates: [Float] = []
    }

    init(target: VSyncHub.LinkTarget) {
        self.target = target
    }

    func attachToCurrentRunLoop() {
        let name = Thread.current.name
        let onMain = Thread.isMainThread
        state.withLock { state in
            state.attachedThread = name
            state.attachedOnMain = onMain
        }
    }

    var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set { state.withLock { $0.paused = newValue } }
    }

    func invalidate() { state.withLock { $0.invalidated = true } }

    func requestFrameRate(_ range: CAFrameRateRange) {
        let preferred = range.preferred ?? range.maximum
        state.withLock { $0.requestedRates.append(preferred) }
    }

    /// The preferred rate of each request, in order.
    var requestedRates: [Float] { state.withLock { $0.requestedRates } }

    var invalidated: Bool { state.withLock { $0.invalidated } }
    var attachedThread: String? { state.withLock { $0.attachedThread } }
    var attachedOnMain: Bool { state.withLock { $0.attachedOnMain } }
}

@MainActor
private final class FakeVSyncLinks {
    private(set) var made: [FakeVSyncLink] = []

    var make: VSyncHub.LinkFactory {
        { [self] _, target in
            let link = FakeVSyncLink(target: target)
            made.append(link)
            return link
        }
    }

    /// One vsync of the newest link of `display`, run on the hub thread as the real link's would.
    func fire(_ hub: VSyncHub, display: CGDirectDisplayID, timestamp: CFTimeInterval,
              targetTimestamp: CFTimeInterval) async throws {
        let target = try #require(made.last).target
        await hub.onHubThread(display) {
            target.vsync(timestamp: timestamp, targetTimestamp: targetTimestamp)
        }
    }
}

/// What the off-main callbacks saw, written on the hub thread and read on main.
private final class CallbackLog: Sendable {
    struct Call: Sendable {
        let onMain: Bool
        let thread: String?
        let sequence: UInt64
    }

    private let log = Mutex<[Call]>([])

    func record(tick: VSyncHub.Tick) {
        let call = Call(onMain: Thread.isMainThread, thread: Thread.current.name, sequence: tick.sequence)
        log.withLock { $0.append(call) }
    }

    var calls: [Call] { log.withLock { $0 } }
}

/// The subscription a callback arms itself through.
private final class SubscriptionSlot: Sendable {
    private let slot = Mutex<VSyncHub.Subscription?>(nil)

    var subscription: VSyncHub.Subscription? {
        get { slot.withLock { $0 } }
        set { slot.withLock { $0 = newValue } }
    }
}

/// The main posts the hub queued; the test runs them on main when it chooses.
private final class MainPosts: Sendable {
    private let queue = Mutex<[@MainActor @Sendable () -> Void]>([])

    var post: VSyncHub.MainPost {
        { [self] body in queue.withLock { $0.append(body) } }
    }

    var count: Int { queue.withLock { $0.count } }

    @MainActor
    func drain() {
        let bodies = queue.withLock { queue in
            defer { queue = [] }
            return queue
        }
        for body in bodies { body() }
    }
}

/// `CACurrentMediaTime` for the hop meter, read on the hub thread and on main.
private final class SharedMediaTime: Sendable {
    private let now = Mutex<CFTimeInterval>(0)

    func set(_ value: CFTimeInterval) { now.withLock { $0 = value } }

    var read: @Sendable () -> CFTimeInterval { { [self] in now.withLock { $0 } } }
}
