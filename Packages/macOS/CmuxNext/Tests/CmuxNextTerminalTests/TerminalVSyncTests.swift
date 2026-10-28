import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import GhosttyNextKit
import QuartzCore
import Testing

/// Ghostty surfaces paced from their display's VSyncHub thread (``TerminalVSync``): a surface
/// holds a subscription only while it draws, on its own display's clock; Ghostty's wanted edge arms it, and the first
/// tick after Ghostty stops wanting frames is empty and disarms it. The source is a fake that counts live
/// subscriptions, except in the hub test, which runs a real ``VSyncHub`` with a fake link on its real thread.
@MainActor @Suite(.timeLimit(.minutes(1))) struct TerminalVSyncTests {
    /// Hidden: no subscription. Drawing: one disarmed subscription; wanted arms it and its ticks refresh the
    /// surface; not wanted: the next tick refreshes nothing and says done. Hidden again: the subscription goes.
    @Test func onlyADrawingSurfaceSubscribesAndAnIdleOneIsDoneAfterOneEmptyTick() throws {
        let source = FakeVSyncSource()
        let pacer = makePacer(fallback: 1)
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })

        pacer.follow(nil, source: source)
        #expect(source.live.isEmpty, "a hidden surface subscribed")

        pacer.follow(1, source: source)
        let subscription = try #require(source.live.first)
        #expect(source.live.count == 1)
        #expect(subscription.display == 1)
        #expect(!subscription.isArmed, "a surface that wants no frame arms nothing")

        pacer.wantedChanged(true)
        #expect(subscription.isArmed)
        #expect(subscription.tick() == .more)
        #expect(subscription.tick() == .more)
        #expect(refreshes.value == 2)

        pacer.wantedChanged(false)
        #expect(subscription.tick() == .done, "an idle surface must disarm after one empty tick")
        #expect(refreshes.value == 2, "an idle surface's tick refreshed it")

        pacer.follow(nil, source: source)
        #expect(source.live.isEmpty, "a surface that stopped drawing kept its subscription")
        #expect(subscription.cancelled)
    }

    /// Ghostty may want frames before the surface is shown (the wanted callback can run before
    /// `ghostty_surface_new` returns): the subscription is armed as it is made.
    @Test func aWantedEdgeBeforeTheSubscriptionArmsIt() throws {
        let source = FakeVSyncSource()
        let pacer = makePacer(fallback: 1)
        pacer.attach(refresh: {})
        pacer.wantedChanged(true)

        pacer.follow(2, source: source)

        let subscription = try #require(source.live.first)
        #expect(subscription.isArmed)
        #expect(subscription.tick() == .more)
    }

    /// A display change moves the subscription to the new display's clock; the old one's ticks refresh nothing.
    /// The same display again changes nothing.
    @Test func aDisplayChangeMovesTheSubscription() throws {
        let source = FakeVSyncSource()
        let pacer = makePacer(fallback: 1)
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })
        pacer.wantedChanged(true)
        pacer.follow(1, source: source)
        let first = try #require(source.live.first)

        pacer.follow(1, source: source)
        #expect(source.made.count == 1, "the same display made a second subscription")

        pacer.follow(2, source: source)
        #expect(first.cancelled)
        let second = try #require(source.live.first)
        #expect(source.live.count == 1)
        #expect(second.display == 2)
        #expect(second.isArmed, "the moved subscription must keep ticking while Ghostty wants frames")
        #expect(first.tick() == .done)
        #expect(refreshes.value == 0, "a tick of the old display's subscription refreshed the surface")
        #expect(second.tick() == .more)
        #expect(refreshes.value == 1)
    }

    /// A display with no screen (no link can exist) paces the surface on the main display's clock.
    @Test func aDisplayWithNoScreenFallsBackToTheMainDisplay() throws {
        let source = FakeVSyncSource(screens: [1])
        let pacer = makePacer(fallback: 1)
        pacer.follow(9, source: source)
        let subscription = try #require(source.live.first)
        #expect(subscription.display == 1)
    }

    /// No screen on the surface's display nor on the main one: no subscription, and a later follow of the same
    /// display tries again; once that display has a screen, it subscribes there and ticks.
    @Test func aSurfaceWithNoScreenAnywhereSubscribesOnceItsScreenAppears() throws {
        let source = FakeVSyncSource(screens: [])
        let pacer = makePacer(fallback: 1)
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })

        pacer.follow(9, source: source)
        #expect(source.made.isEmpty)
        #expect(!pacer.isSubscribed)

        source.screens = [9]
        pacer.follow(9, source: source)
        let subscription = try #require(source.live.first, "the same display's follow did not try again")
        #expect(subscription.display == 9)
        pacer.wantedChanged(true)
        #expect(subscription.isArmed)
        #expect(subscription.tick() == .more)
        #expect(refreshes.value == 1)
    }

    /// A surface on the main display's clock (its own display has no screen) stays there while its own display
    /// has none, and the retry deadline moves it to its own display's clock once that display has a screen.
    @Test func theRetryDeadlineMovesAFallbackSurfaceToItsOwnDisplay() async throws {
        let source = FakeVSyncSource(screens: [1])
        let retryClock = ManualClock()
        let pacer = TerminalVSync(fallback: { 1 }, pacingClock: ManualClock(), retryClock: retryClock, stallClock: ManualClock(),
                                  ledger: WakeupLedger())
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })
        pacer.wantedChanged(true)
        pacer.follow(9, source: source)
        let onMain = try #require(source.live.first)
        #expect(onMain.display == 1)

        pacer.follow(9, source: source)
        #expect(source.made.count == 1, "a follow that still found no screen remade the main display's subscription")

        source.screens = [1, 9]
        let (subscribed, subscribe) = AsyncStream.makeStream(of: CGDirectDisplayID.self)
        source.onSubscribe = { _ = subscribe.yield($0) }
        try await retryClock.waitForSleeper()
        retryClock.advance(by: TerminalVSync.retryInterval)
        var moves = subscribed.makeAsyncIterator()
        let moved = await moves.next()
        #expect(moved == 9)

        #expect(onMain.cancelled)
        let own = try #require(source.live.first)
        #expect(source.live.count == 1)
        #expect(own.display == 9)
        #expect(own.isArmed, "the moved subscription must keep ticking while Ghostty wants frames")
        #expect(onMain.tick() == .done)
        #expect(own.tick() == .more)
        #expect(refreshes.value == 1)
    }

    /// With no subscription anywhere, a surface Ghostty wants frames from still refreshes, on the linkless
    /// deadline; one that wants none runs no deadline.
    @Test func aSurfaceWithNoScreenAnywhereIsPacedOnTheLinklessDeadline() async throws {
        let source = FakeVSyncSource(screens: [])
        let pacingClock = ManualClock()
        let pacer = TerminalVSync(fallback: { 1 }, pacingClock: pacingClock, retryClock: ManualClock(), stallClock: ManualClock(),
                                  ledger: WakeupLedger())
        let (refreshed, refresh) = AsyncStream.makeStream(of: Void.self)
        let refreshes = Counter()
        pacer.attach(refresh: {
            refreshes.add()
            refresh.yield()
        })

        pacer.follow(9, source: source)
        try #require(!pacer.isSubscribed)
        #expect(pacingClock.sleeperCount == 0, "a surface that wants no frame ran the linkless deadline")

        pacer.wantedChanged(true)
        var ticks = refreshed.makeAsyncIterator()
        for expected in 1...2 {
            try await pacingClock.waitForSleeper()
            pacingClock.advance(by: TerminalVSync.linklessInterval)
            _ = await ticks.next()
            #expect(refreshes.value == expected)
        }
    }

    /// An armed surface whose link stops ticking (display sleep, a reconfiguration that keeps the display id) with
    /// no frame scheduler on that display to rebuild it: each stall timeout with no tick refreshes the surface once,
    /// the ``DisplayClock/stallsBeforeRebuild``-th in a row rebuilds the link, and the surface ticks on the new link.
    @Test func anArmedSurfaceWhoseLinkStallsStillRefreshesAndRebuildsTheLink() async throws {
        let source = FakeVSyncSource()
        let stallClock = ManualClock()
        let pacer = TerminalVSync(fallback: { 1 }, pacingClock: ManualClock(), retryClock: ManualClock(), stallClock: stallClock,
                                  ledger: WakeupLedger())
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })
        pacer.wantedChanged(true)
        pacer.follow(1, source: source)
        let subscription = try #require(source.live.first)
        #expect(subscription.tick() == .more)
        #expect(refreshes.value == 1)
        #expect(TerminalVSync.stallTimeout == DisplayClock.stallTimeout, "the surface's stall timeout left the frame clock's")

        // The link ticked in time: the check refreshes nothing.
        try await stallClock.waitForSleeper()
        stallClock.advance(by: TerminalVSync.stallTimeout)
        try await stallClock.waitForSleeper()
        #expect(refreshes.value == 1, "a check after a tick refreshed the surface")
        #expect(subscription.relinks == 0)

        // The link stops: each timeout refreshes once; the last one in a row rebuilds the link.
        for stall in 1...DisplayClock.stallsBeforeRebuild {
            stallClock.advance(by: TerminalVSync.stallTimeout)
            try await stallClock.waitForSleeper()
            #expect(refreshes.value == 1 + stall, "a stalled link left an armed surface with no draw")
        }
        #expect(subscription.relinks == 1, "a link that stalled \(DisplayClock.stallsBeforeRebuild) times was not rebuilt")
        #expect(!subscription.cancelled)
        #expect(subscription.isArmed)
        #expect(subscription.tick() == .more, "the surface does not tick on the rebuilt link")
        #expect(refreshes.value == 2 + DisplayClock.stallsBeforeRebuild)
    }

    /// A stalled link the hub cannot rebuild (its screen went away under the same display id): the surface leaves it
    /// for the main display's clock, armed, instead of keeping a subscription that never ticks.
    @Test func anArmedSurfaceWhoseStalledLinkCannotBeRebuiltMovesToTheMainDisplay() async throws {
        let source = FakeVSyncSource(screens: [1, 9])
        let stallClock = ManualClock()
        let pacer = TerminalVSync(fallback: { 1 }, pacingClock: ManualClock(), retryClock: ManualClock(), stallClock: stallClock,
                                  ledger: WakeupLedger())
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })
        pacer.wantedChanged(true)
        pacer.follow(9, source: source)
        let stuck = try #require(source.live.first)
        #expect(stuck.display == 9)

        source.screens = [1]
        stuck.setCanRelink(false)
        // The new subscription's grace timeout, then the silent ones up to the rebuild.
        for _ in 0...DisplayClock.stallsBeforeRebuild {
            try await stallClock.waitForSleeper()
            stallClock.advance(by: TerminalVSync.stallTimeout)
        }
        try await stallClock.waitForSleeper()

        #expect(stuck.relinks == 1)
        #expect(stuck.cancelled, "the surface kept a link that could not be rebuilt")
        let onMain = try #require(source.live.first)
        #expect(source.live.count == 1)
        #expect(onMain.display == 1)
        #expect(onMain.isArmed, "the moved subscription must keep ticking while Ghostty wants frames")
        #expect(stuck.tick() == .done)
        #expect(onMain.tick() == .more)
        #expect(refreshes.value == DisplayClock.stallsBeforeRebuild + 1)
    }

    /// Closing (before `ghostty_surface_free`) leaves the hub, and no later tick reaches the surface.
    @Test func closeLeavesAndNoTickRefreshesAfterIt() throws {
        let source = FakeVSyncSource()
        let pacer = makePacer(fallback: 1)
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })
        pacer.wantedChanged(true)
        pacer.follow(1, source: source)
        let subscription = try #require(source.live.first)

        pacer.close()

        #expect(source.live.isEmpty)
        #expect(subscription.tick() == .done)
        pacer.follow(1, source: source)
        #expect(source.live.isEmpty, "a closed pacer subscribed again")
        #expect(refreshes.value == 0)
    }

    /// Ghostty's wanted callback gets the surface's bridge as its userdata and reaches the bridge's pacer: the
    /// pacer lives exactly as long as the bridge, which a view freed off main never releases.
    @Test func theWantedCallbackReachesTheBridgesPacer() throws {
        let io = ScriptedTerminalIO()
        let bridge = SurfaceBridge(input: TerminalInputSink(lane: TerminalInputLane(drain: io.inputDrain()),
                                                            typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()))
        let source = FakeVSyncSource()
        bridge.vsync.follow(1, source: source)
        let subscription = try #require(source.live.first)

        unsafe ghosttySurfaceVSyncWanted(Unmanaged.passUnretained(bridge).toOpaque(), true)

        #expect(subscription.isArmed, "the wanted edge did not reach the bridge's pacer")
        bridge.vsync.close()
        #expect(subscription.cancelled)
    }

    /// With the real hub: a visible surface's wanted edge runs its display's link, ticks refresh it on the hub
    /// thread, and once Ghostty stops wanting frames one empty tick disarms it and pauses the link (0 live links).
    @Test func theHubPausesTheLinkAfterAnIdleSurfacesEmptyTick() async throws {
        let links = FakeHubLinks()
        let hub = VSyncHub(makeLink: links.make, postToMain: { _ in })
        defer { hub.stopThreads() }
        let pacer = makePacer(fallback: 3)
        let refreshes = Counter()
        pacer.attach(refresh: { refreshes.add() })

        pacer.follow(3, source: hub)
        await hub.onHubThread(3) {}
        #expect(hub.liveLinks == 0, "a visible surface that wants no frame ran the link")

        pacer.wantedChanged(true)
        await hub.onHubThread(3) {}
        #expect(hub.liveLinks == 1)
        try await links.fire(hub, display: 3)
        #expect(refreshes.value == 1)

        pacer.wantedChanged(false)
        try await links.fire(hub, display: 3)
        #expect(refreshes.value == 1, "an idle surface's tick refreshed it")
        #expect(hub.armedSubscribers(on: 3) == 0, "an idle surface stayed armed after its empty tick")
        #expect(hub.liveLinks == 0)
        let link = try #require(links.made.first)
        #expect(link.isPaused, "nothing armed after the empty tick: the link must pause")

        pacer.close()
        await hub.onHubThread(3) {}
        #expect(hub.pausedLinks == 0, "the closed surface left a link")
    }

    /// The view: a surface that is not in a window holds no subscription; one forced to draw (a live mirror) holds
    /// one; back to not drawing, it holds none.
    @Test func theViewSubscribesOnlyWhileItsSurfaceDraws() throws {
        GhosttyRuntime.startedForTests()
        let source = FakeVSyncSource()
        let io = ScriptedTerminalIO()
        let input = TerminalInputSink(lane: TerminalInputLane(drain: io.inputDrain()),
                                      typingSurface: TypingLatencyProbe.shared.makeSurfaceKey())
        let view = TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL, input: input, session: nil,
                                       echoStages: GhosttyRuntime.shared.echoStages,
                                       secureInput: GhosttyRuntime.shared.secureInput,
                                       mainWork: MainWorkScheduler(budget: MainFrameBudget()), vsyncSource: source)
        try #require(view.surface != nil)
        #expect(view.pause == .notInWindow)
        #expect(source.live.isEmpty, "a surface outside any window subscribed")

        view.mirrorDemand = 1
        #expect(view.pause == nil)
        #expect(source.live.count == 1)

        view.mirrorDemand = 0
        #expect(source.live.isEmpty, "a surface that stopped drawing kept its subscription")
    }
}

/// A count written on any thread.
private nonisolated final class Counter: Sendable {
    private let count = Mutex(0)
    func add() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// A pacer whose deadlines sleep on clocks no test moves, recording into a private ledger.
private func makePacer(fallback: CGDirectDisplayID) -> TerminalVSync {
    TerminalVSync(fallback: { fallback }, pacingClock: ManualClock(), retryClock: ManualClock(), stallClock: ManualClock(),
                  ledger: WakeupLedger())
}

/// A vsync source whose subscriptions the test ticks by hand.
private final class FakeVSyncSource: TerminalVSyncSource {
    /// Displays that have a screen; nil: every display. A test adds a screen by changing it.
    var screens: Set<CGDirectDisplayID>?
    /// Called with the display of each subscription made.
    var onSubscribe: ((CGDirectDisplayID) -> Void)?
    private(set) var made: [FakeSubscription] = []

    init(screens: Set<CGDirectDisplayID>? = nil) {
        self.screens = screens
    }

    var live: [FakeSubscription] { made.filter { !$0.cancelled } }

    func subscribeSurface(to display: CGDirectDisplayID, owner: String,
                          onVSync: @escaping @Sendable (VSyncHub.Tick) -> VSyncHub.Demand) -> (any TerminalVSyncSubscription)? {
        if let screens, !screens.contains(display) { return nil }
        let subscription = FakeSubscription(display: display, onVSync: onVSync)
        made.append(subscription)
        onSubscribe?(display)
        return subscription
    }
}

/// One fake subscription: armed by the pacer, ticked by the test (a `.done` tick disarms, as the hub does).
private nonisolated final class FakeSubscription: TerminalVSyncSubscription {
    let display: CGDirectDisplayID
    private let onVSync: @Sendable (VSyncHub.Tick) -> VSyncHub.Demand
    private let state = Mutex((armed: false, cancelled: false, relinks: 0, canRelink: true))

    init(display: CGDirectDisplayID, onVSync: @escaping @Sendable (VSyncHub.Tick) -> VSyncHub.Demand) {
        self.display = display
        self.onVSync = onVSync
    }

    var isArmed: Bool { state.withLock { $0.armed } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    /// Link rebuilds the pacer asked for.
    var relinks: Int { state.withLock { $0.relinks } }

    /// Whether a rebuild finds a screen (false: the hub drops the stuck link and makes none).
    func setCanRelink(_ canRelink: Bool) { state.withLock { $0.canRelink = canRelink } }

    func arm() { state.withLock { $0.armed = true } }

    @MainActor func relink() -> Bool {
        state.withLock { state in
            state.relinks += 1
            return state.canRelink
        }
    }

    @MainActor func cancel() { state.withLock { $0.cancelled = true } }

    /// One vsync, delivered whether or not it is armed (a stale tick the hub already took).
    func tick() -> VSyncHub.Demand {
        let demand = onVSync(VSyncHub.Tick(display: display, timestamp: 1, targetTimestamp: 1 + 1.0 / 120, sequence: 1))
        if demand == .done { state.withLock { $0.armed = false } }
        return demand
    }
}

/// A hub link whose vsyncs the test fires on the hub thread.
private nonisolated final class FakeHubLink: VSyncLink, Sendable {
    let target: VSyncHub.LinkTarget
    private let paused = Mutex(false)

    init(target: VSyncHub.LinkTarget) {
        self.target = target
    }

    func attachToCurrentRunLoop() {}

    var isPaused: Bool {
        get { paused.withLock { $0 } }
        set { paused.withLock { $0 = newValue } }
    }

    func invalidate() {}

    func requestFrameRate(_ range: CAFrameRateRange) {}
}

private final class FakeHubLinks {
    private(set) var made: [FakeHubLink] = []

    var make: VSyncHub.LinkFactory {
        { [self] _, target in
            let link = FakeHubLink(target: target)
            made.append(link)
            return link
        }
    }

    /// One vsync of the newest link, run on `display`'s hub thread as a real link's would.
    func fire(_ hub: VSyncHub, display: CGDirectDisplayID) async throws {
        let target = try #require(made.last).target
        await hub.onHubThread(display) {
            target.vsync(timestamp: 1, targetTimestamp: 1 + 1.0 / 120)
        }
    }
}
