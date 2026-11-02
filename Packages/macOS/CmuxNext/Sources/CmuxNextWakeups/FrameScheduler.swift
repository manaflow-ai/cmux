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
    /// Sets the link's preferred frame rate range.
    @MainActor public func requestFrameRate(_ range: CAFrameRateRange) { preferredFrameRateRange = range }
}

/// The frame clock of a window (architecture.md 3 and 5): it subscribes to its display's one link
/// on the shared ``DisplayClock`` only while at least one ``FrameClient`` is active, and leaves when
/// the last one goes idle (or is parked, ``FrameClient/visibleOnly``), so an idle window has no frame wakeups.
///
/// Every animation, drag autoscroll, resize settle and per-frame batch in CmuxNext is a client of
/// its window's scheduler; window-less frame work uses ``app``, on the main display. Budgeted
/// batches (the daemon store drain, the control work queue) tick on the app's one
/// ``MainWorkScheduler``, the only scheduler that holds a ``MainFrameBudget``. All of them share one
/// link per display (``DisplayClock``, the only code that creates one, as
/// `scripts/cmux-next/check-concurrency.sh` enforces), which also runs the display's stall deadline.
/// The composition root builds that clock, installs it here (``install(displays:energy:)``) and passes it to
/// its ``MainWorkScheduler``. Every scheduler follows the app's Energy Saver policy (FrameScheduler+Energy.swift).
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
    /// (``install(displays:energy:)``; a clock of its own before that, in tests).
    public private(set) static var app = FrameScheduler(name: "app", host: .screen, displays: DisplayClock(), budget: nil)

    /// The display clock ``app`` and the window schedulers subscribe to.
    public static var appDisplays: DisplayClock { app.displayClock }

    /// Puts ``app`` and the window schedulers made from now on onto `displays`, the composition root's
    /// one clock, under `energy`, the app's one Energy Saver policy (`MainWorkScheduler.energy`), which
    /// the window schedulers follow too. Called once at launch, before any window has a scheduler.
    public static func install(displays: DisplayClock, energy: EnergyPolicySource) {
        if displays !== appDisplays {
            app.invalidate()
            app = FrameScheduler(name: "app", host: .screen, displays: displays, budget: nil)
        }
        app.follow(energy)
    }

    enum Host {
        case screen
        case window(NSWindow)
    }

    /// The scheduler's name in the wakeup ledger and signposts.
    public let name: String
    /// The window it clocks; nil for a screen-hosted scheduler or once the window is gone.
    public private(set) weak var window: NSWindow?
    /// The scheduler serves window-less work on a display (``app``, the ``MainWorkScheduler``'s).
    let isScreenHost: Bool
    private(set) var clients: [ObjectIdentifier: FrameClient] = [:]
    /// The budgeted clients, the one that ran least recently first: a class's budget goes to them
    /// in this order, and a client that ran moves to the back, so one saturating client never
    /// keeps the others of its class from ticking (round-robin).
    var budgetedOrder: [ObjectIdentifier] = []
    /// The clock this scheduler subscribes to.
    public let displayClock: DisplayClock
    /// The display this scheduler last subscribed to (kept after it leaves, for its stall stats);
    /// ``isSubscribed`` says whether it ticks on that display now.
    private var displayID: CGDirectDisplayID?
    private var isSubscribed = false
    /// Its display has a link now (a headless one ticks on the stall deadline only); the clock says
    /// when the link comes or goes (``displayLinkDidChange(exists:)``).
    private var ticksOnLink = false {
        didSet {
            guard oldValue != ticksOnLink else { return }
            if reportsUnbudgeted { displayClock.unbudgetedLinks.linkChanged(exists: ticksOnLink) }
            onLinkChange?(ticksOnLink)
        }
    }
    /// ``app`` and the window schedulers report to their clock's ``DisplayClock/unbudgetedLinks``;
    /// the budgeted one does not.
    private let reportsUnbudgeted: Bool
    /// Told when the scheduler starts and stops ticking on its display's link (the
    /// ``MainWorkScheduler``: its ticks own the budget's window, and render passes are timed only
    /// while they come).
    var onLinkChange: (@MainActor (_ exists: Bool) -> Void)?
    /// Told after each of its display-link frames with its timestamp and refresh period (the
    /// ``MainWorkScheduler``: a short idle period may follow the frame's render pass, until one
    /// millisecond before the next vsync). Stall-deadline ticks have no vsync and are not reported.
    var onLinkFrame: (@MainActor (_ timestamp: CFTimeInterval, _ refreshInterval: Double) -> Void)?
    /// Takes each tick's budgeted batch out of the tick (the ``MainWorkScheduler``'s after-commit
    /// placement), which runs it in a turn of its own (``runBudgeted(_:)``); nil: it runs in the tick.
    var defersBudgeted: (@MainActor (FrameTick) -> Void)?
    /// The link frame this scheduler ticks in now, reported when its part of the frame ends.
    private var linkFrame: (timestamp: CFTimeInterval, refreshInterval: Double)?
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
    /// Lets go of it when its window closes (window schedulers only): a ``WindowEvents`` subscription.
    var closeObserver: EventSubscription?
    /// Moves it to its window's new display when the window changes screen (window schedulers only).
    var screenFamily: WindowScreenFamily?
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
    /// The highest ``FrameClient/rate`` of its active clients (nil while idle); ``linkRate`` is what
    /// it asks of its display's link (``DisplayClock``).
    public private(set) var frameRate: FrameRate?
    /// Energy Saver's ambient cap and the ambient clients waiting out display sleep (FrameScheduler+Energy.swift).
    var energyState = AmbientEnergyState()
    /// Its window's occlusion and the clients waiting it out (FrameScheduler+Occlusion.swift).
    var occlusionHold = OcclusionHold()
    /// Its motion and commit-window frame sequences (FrameSequenceTracker.swift).
    public let sequences: FrameSequenceTracker

    /// - Parameters:
    ///   - displays: The clock to subscribe to (the app's: ``appDisplays``).
    ///   - sequences: Its frame sequences (nil: one on the app's trace runtime).
    init(name: String, host: Host, displays: DisplayClock, clock: any Clock<Duration> = ContinuousClock(),
         ledger: WakeupLedger = .shared, budget: MainFrameBudget?, sequences: FrameSequenceTracker? = nil) {
        self.budget = budget
        self.sequences = sequences ?? FrameSequenceTracker()
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
        reportsUnbudgeted = budget == nil
        super.init()
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

    /// This scheduler's continuous input, delivered before its frame clients (made on first use; kept, with
    /// its work dropped, when its window closes, so a window shown again keeps it). Get it through ``FrameInputCoalescers``.
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

    /// A budgeted client still has work queued: it stays in the round-robin until it goes idle.
    var hasBudgetedWork: Bool { !budgetedOrder.isEmpty }

    // MARK: Clients

    func activate(_ client: FrameClient) {
        let key = ObjectIdentifier(client)
        if waitsForScreens(client) || waitsForVisibleWindow(client) { return }
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
        sequences.linkDidChange()
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
        energyState.asleep[ObjectIdentifier(client)] = nil
        occlusionHold.held[ObjectIdentifier(client)] = nil
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
        sequences.closeAll()
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
        for client in clients.values { client.detach() }
        clients.removeAll()
        detachAsleep()
        detachOccluded()
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
    /// (``ticksOffLink``). `seen`: someone can see its window (false for a hidden window's stall-rate tick).
    func beginFrame(timestamp: CFTimeInterval?, refreshInterval: Double?, targetTimestamp: CFTimeInterval?,
                    offLink: Bool, seen: Bool = true) -> FrameTick {
        frames &+= 1
        // When the tick runs on main, not the frame's vsync time: the guard measures main's lateness.
        let ranAt = displayClock.now()
        starvation?.tickEnds(self, at: ranAt)
        lastTick = ranAt
        ticksOffLink = offLink
        let now = timestamp ?? ranAt
        // The first frame after the link was idle has no previous one: it steps by the display's own refresh
        // period (one frame of motion, as every frame after it), not 1/60 s, which put the first moving frame of
        // every animation from rest two refreshes along its curve at 120 Hz. A synthesized frame has none: 1/60.
        let firstElapsed = refreshInterval.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? (1.0 / 60.0)
        let elapsed = lastTimestamp.map { now - $0 } ?? firstElapsed
        lastTimestamp = now
        if let refreshInterval { lastRefreshInterval = refreshInterval }
        if !offLink, ticksOnLink, let timestamp, let refreshInterval {
            linkFrame = (timestamp, refreshInterval)
        } else {
            linkFrame = nil
        }
        // Visible motion (not batch work) explains CPU use to the busy watchdog.
        if clients.values.contains(where: { $0.isActive && $0.isAnimation }) {
            ExpectedActivity.shared.note(.animationFrame)
        }
        // A tick with no vsync while its link runs for a window someone sees: the vsyncs it missed are drops.
        sequences.frameBegan(linkFrame, vsyncsGoOn: seen && isRunning)
        budget?.beginFrame(timestamp: timestamp, targetTimestamp: targetTimestamp, refreshInterval: refreshInterval, ranAt: ranAt)
        // A stalled frame keeps refreshInterval nil (`SwitchFrameTimer` reads nil as a stall), but is
        // still shown one link interval after it starts (Chrome's synthetic sources: frame_time + interval).
        let target = targetTimestamp ?? now + lastRefreshInterval
        lastTargetTimestamp = target
        return FrameTick(timestamp: now, elapsed: min(max(elapsed, 1.0 / 240.0), 1.0 / 30.0),
                         rawElapsed: elapsed, refreshInterval: refreshInterval,
                         targetTimestamp: target, sequence: frames)
    }

    /// The frame-locked clients, every frame: the input stage first (the window's input coalescers),
    /// then the frame clients, so they see this frame's input. A frame client the input stage
    /// activated (a ghost spring a trailing move woke) ticks in this frame too, as Blink dispatches
    /// rAF-aligned input before the frame's animation callbacks (`WidgetBase::BeginMainFrame`,
    /// `third_party/blink/renderer/platform/widget/widget_base.cc`). Clients a frame client
    /// activates tick next frame.
    func deliverFrameLocked(_ tick: FrameTick) { // perf-hot: 0.5ms frame-tick (every frame)
        for client in clients.values.filter({ $0.isActive && $0.workClass == .input }) {
            fire(client, tick)
        }
        for client in clients.values.filter({ $0.isActive && $0.workClass == .frame }) {
            fire(client, tick)
        }
    }

    /// Ends this scheduler's part of a frame: reports a link frame (``onLinkFrame``, and for ``app``
    /// and the windows their clock's ``DisplayClock/unbudgetedLinks``), then with no client left it
    /// leaves the display.
    func endFrame() {
        if let frame = linkFrame {
            linkFrame = nil
            onLinkFrame?(frame.timestamp, frame.refreshInterval)
            if reportsUnbudgeted { displayClock.unbudgetedLinks.frame(timestamp: frame.timestamp, refreshInterval: frame.refreshInterval) }
        }
        if clients.isEmpty { pause() }
    }

    /// Ticks `client` and records its wakeup, unless an earlier tick of this frame stopped or parked it
    /// (it left ``clients``): a client that does not run is not counted.
    func fire(_ client: FrameClient, _ tick: FrameTick) {
        let id = ObjectIdentifier(client)
        guard clients[id] === client, client.isActive else { return }
        ledger.record(client.owner, reason: "frame")
        if !client.fire(tick) { drop(id) }
    }
}
