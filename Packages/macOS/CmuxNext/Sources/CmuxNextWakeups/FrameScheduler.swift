public import AppKit
public import QuartzCore
import CmuxNextCompat

/// What a scheduler needs from a display link (a fake in tests).
@MainActor
public protocol FrameLink: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
    /// Asks the link to fire at `range` (``DisplayClock``'s rate decision).
    func requestFrameRate(_ range: CAFrameRateRange)
}

extension FrameLink {
    /// A link with no rate of its own (a test fake that is fired by hand) ignores the request.
    public func requestFrameRate(_ range: CAFrameRateRange) {}
}

extension CADisplayLink: FrameLink {
    @MainActor public func requestFrameRate(_ range: CAFrameRateRange) { preferredFrameRateRange = range }
}

/// The frame clock of a window (architecture.md 3 and 5): it subscribes to its display's one link
/// on the shared ``DisplayClock`` only while at least one ``FrameClient`` is active, and leaves when
/// the last one goes idle, so an idle window has no frame wakeups.
///
/// Every animation, drag autoscroll, resize settle and per-frame batch in CmuxNext is a client of
/// its window's scheduler; window-less frame work uses ``app``, on the main display. Budgeted
/// batches (the daemon store drain, the control work queue) tick on the app's one
/// ``MainWorkScheduler``, the only scheduler that holds a ``MainFrameBudget``. All of them share one
/// link per display (``DisplayClock``, the only code that creates one, as
/// `scripts/cmux-next/check-concurrency.sh` enforces), which also runs the display's stall deadline.
/// The composition root builds that clock, installs it here (``install(displays:)``) and passes it to
/// its ``MainWorkScheduler``.
@MainActor
public final class FrameScheduler: NSObject {
    /// Makes a test scheduler's fake link (``testing(clock:ledger:mediaTime:makeLink:)``).
    public typealias LinkFactory = @MainActor (FrameScheduler) -> (any FrameLink)?

    /// Longest wait for a frame while clients are active.
    public static let stallTimeout: Duration = DisplayClock.stallTimeout
    /// Consecutive stalls after which the link is replaced.
    public static let stallsBeforeRebuild = DisplayClock.stallsBeforeRebuild

    /// The scheduler for window-less frame work, on the main display (no budget: budgeted batches
    /// tick on the injected ``MainWorkScheduler``), on the clock the composition root installed
    /// (``install(displays:)``; a clock of its own before that, in tests).
    public private(set) static var app = FrameScheduler(name: "app", host: .screen, displays: DisplayClock(), budget: nil)

    private static var windows: [ObjectIdentifier: WeakScheduler] = [:]

    /// The display clock ``app`` and the window schedulers subscribe to.
    public static var appDisplays: DisplayClock { app.displayClock }

    /// Puts ``app`` and the window schedulers made from now on onto `displays`, the composition root's
    /// one clock. Called once at launch, before any window has a scheduler.
    public static func install(displays: DisplayClock) {
        guard displays !== appDisplays else { return }
        app.invalidate()
        app = FrameScheduler(name: "app", host: .screen, displays: displays, budget: nil)
    }

    /// `window`'s scheduler, created on first use and dropped with the window.
    public static func forWindow(_ window: NSWindow) -> FrameScheduler {
        let key = ObjectIdentifier(window)
        if let scheduler = windows[key]?.value, scheduler.window === window { return scheduler }
        windows = windows.filter { $0.value.value?.window != nil }
        let scheduler = FrameScheduler(name: "window \(window.windowNumber)", host: .window(window), displays: appDisplays, budget: nil)
        windows[key] = WeakScheduler(value: scheduler)
        // The window keeps its scheduler alive.
        objc_setAssociatedObject(window, &FrameScheduler.associationKey, scheduler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // A window's late frames hold work like the app's (RenderStarvationGuard/watch(_:)).
        app.starvation?.watch(scheduler)
        // A subscribed scheduler is held by its display: let go of it when the window closes.
        scheduler.closeObserver = MainActorObservation(NSWindow.willCloseNotification, object: window) { [weak scheduler] in
            scheduler?.invalidate()
        }
        // It ticks on the display the window is on: the window going to another screen moves it there.
        scheduler.screenFamily = WindowScreenFamily(window: window, scheduler: scheduler)
        return scheduler
    }

    /// The scheduler of `view`'s window, or ``app`` while it has none.
    public static func forView(_ view: NSView) -> FrameScheduler {
        view.window.map(forWindow) ?? app
    }

    /// Every live scheduler (debug.wakeups).
    public static var all: [FrameScheduler] {
        [app] + windows.values.compactMap(\.value)
    }

    private static var associationKey: UInt8 = 0

    enum Host {
        case screen
        case window(NSWindow)
    }

    public let name: String
    public private(set) weak var window: NSWindow?
    /// The scheduler serves window-less work on a display (``app``, the ``MainWorkScheduler``'s).
    let isScreenHost: Bool
    private var clients: [ObjectIdentifier: FrameClient] = [:]
    /// The budgeted clients, the one that ran least recently first: a class's budget goes to them
    /// in this order, and a client that ran moves to the back, so one saturating client never
    /// keeps the others of its class from ticking (round-robin).
    private var budgetedOrder: [ObjectIdentifier] = []
    /// The clock this scheduler subscribes to.
    public let displayClock: DisplayClock
    /// The display this scheduler last subscribed to (kept after it leaves, for its stall stats);
    /// ``isSubscribed`` says whether it ticks on that display now.
    private var displayID: CGDirectDisplayID?
    private var isSubscribed = false
    /// Its display has a link now (a headless one ticks on the stall deadline only); the clock says
    /// when the link comes or goes (``displayLinkDidChange(exists:)``).
    private var ticksOnLink = false {
        didSet { if oldValue != ticksOnLink { onLinkChange?(ticksOnLink) } }
    }
    /// Told when the scheduler starts and stops ticking on its display's link (the
    /// ``MainWorkScheduler``: its ticks own the budget's window, and render passes are timed only
    /// while they come).
    var onLinkChange: (@MainActor (_ exists: Bool) -> Void)?
    private let ledger: WakeupLedger
    private let clock: any Clock<Duration>
    private var madeInput: FrameInputCoalescer?
    private var lastTimestamp: CFTimeInterval?
    /// The link's last refresh period: a stalled frame is shown this long after it starts.
    private var lastRefreshInterval = FrameTick.defaultRefreshInterval
    /// When its clients last ticked, or, idle before, activated (``DisplayClock/now()``'s timebase):
    /// ``RenderStarvationGuard`` measures a late frame from it.
    public private(set) var lastTick: CFTimeInterval = 0
    /// Its last tick came from the stall deadline, not from its display's link: the link stopped (a
    /// ``FrameStall``), or nobody can see its window and it ticks at the stall rate. A late tick then
    /// says nothing about the main thread.
    public private(set) var ticksOffLink = false
    /// The guard that watches its frames (``RenderStarvationGuard/watch(_:)``).
    weak var starvation: RenderStarvationGuard?
    /// The late period the guard saw since ``lastTick`` (stale once it moves).
    var starvationPeriod: RenderStarvationGuard.Period?
    private var closeObserver: MainActorObservation?
    /// Moves it to its window's new display when the window changes screen (window schedulers only).
    private var screenFamily: WindowScreenFamily?
    /// When the frame of its last tick is shown (nil before the first tick after subscribing).
    private var lastTargetTimestamp: CFTimeInterval?
    /// Set when it moves to another display: its last tick there. Until a link tick of the new display
    /// starts more than half that display's interval after it and is shown after it, that display's
    /// ticks pass it by, so its tick time never runs back and no refresh gets two frames (Chrome's
    /// `kDoubleTickDivisor` check, `frame_time > last.frame_time + interval / kDoubleTickDivisor`,
    /// in `DelayBasedBeginFrameSource::IssueBeginFrameToObserver`,
    /// components/viz/common/frame_sinks/begin_frame_source.cc).
    private var handoff: Handoff?
    private struct Handoff {
        let timestamp: CFTimeInterval
        let target: CFTimeInterval
    }
    /// Frames delivered since creation (debug).
    public private(set) var frames: UInt64 = 0
    /// Display links this scheduler's subscribing made since creation (debug: a scheduler that stays
    /// subscribed through a backlog makes one per burst; joining a display that has a link makes none).
    public private(set) var linksMade: UInt64 = 0
    /// The budget its budgeted clients draw on: only a ``MainWorkScheduler``'s scheduler has one
    /// (and only that scheduler gets budgeted clients); nil for ``app`` and window schedulers.
    let budget: MainFrameBudget?
    /// The highest ``FrameClient/rate`` of its active clients (nil while idle): what it asks of
    /// its display's link (``DisplayClock``).
    public private(set) var frameRate: FrameRate?

    /// - Parameter displays: The clock to subscribe to (the app's: ``appDisplays``).
    init(name: String, host: Host, displays: DisplayClock, clock: any Clock<Duration> = ContinuousClock(),
         ledger: WakeupLedger = .shared, budget: MainFrameBudget?) {
        self.budget = budget
        self.name = name
        switch host {
        case .screen: isScreenHost = true
        case .window(let window):
            isScreenHost = false
            self.window = window
        }
        displayClock = displays
        self.ledger = ledger
        self.clock = clock
        super.init()
    }

    /// A scheduler with a fake link on a display clock of its own (tests; budgeted work:
    /// ``MainWorkScheduler/testing(budget:clock:ledger:makeLink:)``). `clock` runs the stall timer;
    /// `mediaTime` stands in for `CACurrentMediaTime`, the timebase of frame timestamps.
    public static func testing(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                               mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                               makeLink: @escaping LinkFactory) -> FrameScheduler {
        testing(name: "test", clock: clock, ledger: ledger, mediaTime: mediaTime, budget: nil, makeLink: makeLink)
    }

    /// A scheduler named `name` on a one-display clock whose links `makeLink` makes for it.
    static func testing(name: String, clock: any Clock<Duration>, ledger: WakeupLedger,
                        mediaTime: @escaping @MainActor () -> CFTimeInterval, budget: MainFrameBudget?,
                        makeLink: @escaping LinkFactory) -> FrameScheduler {
        let owner = TestLinkOwner()
        let displays = DisplayClock(makeLink: { _, _ in
            guard let scheduler = owner.scheduler else { return nil }
            return makeLink(scheduler)
        }, displayOf: { _ in 1 }, clock: clock, ledger: ledger, mediaTime: mediaTime)
        let scheduler = FrameScheduler(name: name, host: .screen, displays: displays, clock: clock, ledger: ledger, budget: budget)
        owner.scheduler = scheduler
        return scheduler
    }

    /// Owners of the clients that are ticking now.
    public var activeClients: [String] {
        clients.values.filter(\.isActive).map(\.owner).sorted()
    }

    /// A frame-locked client (``MainWorkClass/frame``: a spring, an autoscroll, a drain) is ticking:
    /// a late tick of this scheduler is a late frame.
    public var hasActiveFrameClients: Bool {
        clients.values.contains { $0.isActive && $0.workClass == .frame }
    }

    /// Its display's link's last refresh period (a 60 Hz frame before the first link frame).
    public var refreshPeriod: CFTimeInterval { lastRefreshInterval }

    /// When the frame of its last tick is shown (the frame deadline main-thread work ahead of that
    /// frame must meet), in `CACurrentMediaTime` seconds; nil while idle. It may be past: the next
    /// frame's is one ``refreshPeriod`` later.
    public var frameTarget: CFTimeInterval? { lastTargetTimestamp }

    /// The display it ticks on now (nil while idle or never subscribed).
    var display: CGDirectDisplayID? { subscribed }

    /// Its display's link exists and runs, and this scheduler ticks on it.
    public var isRunning: Bool { subscribed.map { displayClock.isRunning($0) } ?? false }

    /// This scheduler's continuous input, coalesced to its frames and delivered before its frame
    /// clients (made on first use; dropped with the scheduler's window).
    public var input: FrameInputCoalescer {
        if let madeInput { return madeInput }
        let made = FrameInputCoalescer(scheduler: self, clock: clock, ledger: ledger)
        madeInput = made
        return made
    }

    /// A display link ticks this scheduler (only while clients are active).
    public var hasLink: Bool { subscribed.map { displayClock.hasLink($0) } ?? false }

    /// Times its display's stall timer was armed (each arm is one task and one cooperative-pool wake).
    public var stallTimerArms: Int { displayID.map { displayClock.stallTimerArms(on: $0) } ?? 0 }
    /// The last frame stall its display saw (debug and tests).
    public var lastStall: FrameStall? { displayID.flatMap { displayClock.lastStall(on: $0) } }

    /// The display it ticks on now.
    private var subscribed: CGDirectDisplayID? { isSubscribed ? displayID : nil }

    /// The window whose display it ticks on (nil: a screen host, on the main display).
    var hostWindow: NSWindow? { isScreenHost ? nil : window }

    /// The timestamp of its last tick while subscribed (nil before the first one).
    var lastTickTimestamp: CFTimeInterval? { lastTimestamp }

    /// True for the ``MainWorkScheduler``'s scheduler: its budgeted classes tick last on its display.
    var holdsBudget: Bool { budget != nil }

    // MARK: Clients

    func activate(_ client: FrameClient) {
        let key = ObjectIdentifier(client)
        clients[key] = client
        if client.workClass.isBudgeted, !budgetedOrder.contains(key) { budgetedOrder.append(key) }
        guard !isSubscribed else { return updateFrameRate() }
        frameRate = FrameRate.highest(of: clients.values.map(\.rate))
        let linksBefore = displayClock.linksMade
        lastTimestamp = nil
        lastTick = displayClock.now()
        ticksOffLink = false
        let id = displayClock.subscribe(self)
        displayID = id
        isSubscribed = true
        if displayClock.linksMade != linksBefore { linksMade += 1 }
        ticksOnLink = displayClock.hasLink(id)
    }

    /// Its display's link was made or dropped (the clock, on a stall rebuild or a failed one).
    func displayLinkDidChange(exists: Bool) {
        guard isSubscribed else { return }
        ticksOnLink = exists
    }

    /// The clock moved it to `id` (its screen changed or went away): it ticks on `id`'s link from its
    /// next frame shown after its last one.
    func displayDidChange(to id: CGDirectDisplayID, hasLink: Bool) {
        displayID = id
        ticksOnLink = hasLink
        if let lastTimestamp, let lastTargetTimestamp {
            handoff = Handoff(timestamp: lastTimestamp, target: lastTargetTimestamp)
        } else {
            handoff = nil
        }
    }

    /// Whether a tick of its display goes to it. After a display change only a link tick that starts
    /// more than half the new interval after its last tick and is shown after its last frame does,
    /// and the first one ends the handoff: tick times never decrease and no refresh gets two frames.
    /// A stall tick (no timestamp, it runs now) always does.
    func takesTick(timestamp: CFTimeInterval?, refreshInterval: Double?, targetTimestamp: CFTimeInterval?) -> Bool {
        guard let last = handoff else { return true }
        if let timestamp {
            let interval = refreshInterval ?? lastRefreshInterval
            let target = targetTimestamp ?? timestamp + interval
            guard timestamp > last.timestamp + interval / 2,
                  target > last.target + Self.handoffSlack
            else { return false }
        }
        handoff = nil
        return true
    }

    /// Two targets closer than this are one refresh (float rounding of link times).
    private static let handoffSlack: CFTimeInterval = 0.0005

    /// Its window moved to another screen (its ``WindowScreenFamily``): tick on that screen's link
    /// now (the display's stall deadline also moves it, within a ``stallTimeout``, as a backstop).
    func screenDidChange() {
        guard let subscribed else { return }
        displayClock.resubscribe(self, from: subscribed)
    }

    func deactivate(_ client: FrameClient) {
        drop(ObjectIdentifier(client))
        if clients.isEmpty { pause() }
    }

    private func drop(_ id: ObjectIdentifier) {
        clients[id] = nil
        budgetedOrder.removeAll { $0 == id }
        updateFrameRate()
    }

    /// Recomputes ``frameRate`` after a client came or went and, when it changed while subscribed,
    /// tells the display, whose link may run at another rate now.
    private func updateFrameRate() {
        let rate = FrameRate.highest(of: clients.values.map(\.rate))
        guard rate != frameRate else { return }
        frameRate = rate
        if let subscribed, rate != nil { displayClock.frameRateDidChange(on: subscribed) }
    }

    /// Leaves the display while idle: an idle window holds no subscription (and its display drops
    /// the link once nobody else ticks on it); the next client subscribes again.
    private func pause() {
        lastTimestamp = nil
        lastTargetTimestamp = nil
        handoff = nil
        guard let subscribed else { return }
        isSubscribed = false
        ticksOnLink = false
        displayClock.unsubscribe(self, from: subscribed)
        // No frame of it can be late now: what waited for one goes on.
        starvation?.framesEnded(self)
    }

    /// Drops the subscription and every client (the window closed).
    public func invalidate() {
        madeInput?.invalidate()
        madeInput = nil
        for client in clients.values { client.detach() }
        clients.removeAll()
        budgetedOrder.removeAll()
        frameRate = nil
        pause()
        closeObserver = nil
    }

    // MARK: Frames

    /// One display frame (tests call it directly): on its display every scheduler there ticks; a
    /// scheduler without a display (headless) ticks alone. `targetTimestamp`: when the frame is shown
    /// (the link's); nil is `timestamp` plus `refreshInterval` (nil: the link's last interval).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil,
                             targetTimestamp: CFTimeInterval? = nil) {
        if let subscribed {
            displayClock.displayDidFire(subscribed, timestamp: timestamp, refreshInterval: refreshInterval,
                                        targetTimestamp: targetTimestamp)
            return
        }
        let tick = beginFrame(timestamp: timestamp, refreshInterval: refreshInterval, targetTimestamp: targetTimestamp,
                              offLink: timestamp == nil)
        deliverFrameLocked(tick)
        deliverBudgeted(tick)
        endFrame()
    }

    /// Starts this scheduler's part of a frame: its tick (with its own elapsed time) and, on the
    /// budget holder, the budget's frame window. `offLink`: the stall deadline ticks it, not the link
    /// (``ticksOffLink``).
    func beginFrame(timestamp: CFTimeInterval?, refreshInterval: Double?, targetTimestamp: CFTimeInterval?,
                    offLink: Bool) -> FrameTick {
        frames &+= 1
        // When the tick runs on main, not the frame's vsync time: the guard measures main's lateness.
        let ranAt = displayClock.now()
        starvation?.tickEnds(self, at: ranAt)
        lastTick = ranAt
        ticksOffLink = offLink
        let now = timestamp ?? ranAt
        let elapsed = lastTimestamp.map { now - $0 } ?? (1.0 / 60.0)
        lastTimestamp = now
        if let refreshInterval { lastRefreshInterval = refreshInterval }
        // Visible motion (not batch work) explains CPU use to the busy watchdog.
        if clients.values.contains(where: { $0.isActive && $0.isAnimation }) {
            ExpectedActivity.shared.note(.animationFrame)
        }
        budget?.beginFrame(timestamp: timestamp, targetTimestamp: targetTimestamp, refreshInterval: refreshInterval, ranAt: ranAt)
        // A stalled frame keeps refreshInterval nil (`SwitchFrameTimer` reads nil as a stall), but is
        // still shown one link interval after it starts (Chrome's synthetic sources: frame_time + interval).
        let target = targetTimestamp ?? now + lastRefreshInterval
        lastTargetTimestamp = target
        return FrameTick(timestamp: now, elapsed: min(max(elapsed, 1.0 / 240.0), 1.0 / 30.0),
                         rawElapsed: elapsed, refreshInterval: refreshInterval,
                         targetTimestamp: target, sequence: frames)
    }

    /// The frame-locked clients, every frame: the input stage first (the window's
    /// FrameInputCoalescer), so the frame clients see this frame's input. Clients activated during
    /// this frame tick next frame.
    func deliverFrameLocked(_ tick: FrameTick) { // perf-hot: 0.5ms frame-tick (every frame)
        let ticking = clients.values.filter(\.isActive)
        for client in ticking where client.workClass == .input {
            fire(client, tick)
        }
        for client in ticking where client.workClass == .frame {
            fire(client, tick)
        }
    }

    /// Only on the scheduler that holds the budget, after every other scheduler on its display: the
    /// budgeted batches in class order, each only while its class may run (a held one stays active
    /// and ticks next frame: input pending, or the class's budget spent).
    func deliverBudgeted(_ tick: FrameTick) {
        guard let budget else { return }
        let order = budgetedOrder
        for workClass in MainWorkClass.budgeted {
            for id in order {
                guard let client = clients[id], client.workClass == workClass, client.isActive else { continue }
                guard budget.mayRun(workClass) else { break }
                fire(client, tick)
                // It ran: the clients of its class that did not get to run go first next frame.
                if clients[id] != nil {
                    budgetedOrder.removeAll { $0 == id }
                    budgetedOrder.append(id)
                }
            }
        }
    }

    /// Ends this scheduler's part of a frame: with no client left it leaves the display.
    func endFrame() {
        if clients.isEmpty { pause() }
    }

    private func fire(_ client: FrameClient, _ tick: FrameTick) {
        ledger.record(client.owner, reason: "frame")
        if !client.fire(tick) { drop(ObjectIdentifier(client)) }
    }

    private struct WeakScheduler {
        weak var value: FrameScheduler?
    }

    /// Lets a test clock's link factory reach the scheduler it was made for.
    @MainActor
    private final class TestLinkOwner {
        weak var scheduler: FrameScheduler?
    }
}
