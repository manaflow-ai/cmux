import AppKit
import CmuxNextCompat
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// VSyncHub (p03-rendering-014): each display's only link lives on that display's vsync thread,
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

    /// No subscriber: no link. Subscribed but not armed: the link is paused (no wake). A tick that
    /// returns `.done` disarms and pauses; the last subscriber leaving drops the link.
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
        #expect(hub.liveLinks == 1)
        #expect(link.isPaused, "no subscriber is armed: the link must not wake the thread")

        try await links.fire(hub, display: 1, timestamp: 1, targetTimestamp: 1.01)
        #expect(seen.calls.isEmpty, "a disarmed subscriber ticked")

        surface.arm()
        await hub.onHubThread(1) {}
        #expect(!link.isPaused)
        #expect(hub.armedSubscribers(on: 1) == 1)

        try await links.fire(hub, display: 1, timestamp: 2, targetTimestamp: 2.01)
        #expect(seen.calls.count == 1)
        #expect(hub.armedSubscribers(on: 1) == 0, "an empty tick disarms")
        #expect(link.isPaused, "nothing armed after the tick: the link pauses")

        surface.cancel()
        await hub.onHubThread(1) {}
        #expect(hub.liveLinks == 0)
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
        #expect(mainTicks == [10 + 3.0 / 120], "main ticks once, with the newest vsync")
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

    /// A display with no screen gets no link and no subscription.
    @Test func aDisplayWithNoScreenGetsNoLink() {
        let hub = VSyncHub(makeLink: { _, _ in nil }, postToMain: { _ in })
        defer { hub.stopThreads() }
        #expect(hub.subscribe(to: 3, owner: "surface", armed: true) { _ in .more } == nil)
        #expect(hub.liveLinks == 0)
        #expect(hub.linksMade == 0)
    }
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
