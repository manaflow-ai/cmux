public import AppKit
public import QuartzCore
import CmuxNextCompat

/// What a scheduler needs from a display link (a fake in tests).
@MainActor
public protocol FrameLink: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

extension CADisplayLink: FrameLink {}

/// The one display link of a window (architecture.md 3 and 5): it runs only
/// while at least one ``FrameClient`` is active and pauses itself when the
/// last one goes idle (dropping the link), so an idle window has no frame
/// wakeups.
///
/// Every animation, drag autoscroll, resize settle and per-frame batch in
/// CmuxNext is a client of its window's scheduler; window-less frame work
/// uses ``app``, bound to the main screen. Budgeted batches (the daemon store
/// drain, the control work queue) tick on the app's one ``MainWorkScheduler``,
/// the only scheduler that holds a ``MainFrameBudget``. No other code may
/// create a display link (`scripts/cmux-next/check-concurrency.sh`).
///
/// A display link stops firing while the displays sleep, when its screen
/// goes away, and for some occluded windows, yet clients such as the daemon
/// mirror must keep moving. So while any client is active a one-shot stall
/// deadline runs: when no frame came in time the clients tick anyway, and
/// after repeated stalls the link is rebuilt. Frames do not touch the
/// deadline (a new timer task per frame cost two cooperative-pool wakes a
/// frame): when it fires after a frame came, it is armed again for the rest
/// of the timeout from that frame, about ten arms a second while ticking.
@MainActor
public final class FrameScheduler: NSObject {
    public typealias LinkFactory = @MainActor (FrameScheduler) -> (any FrameLink)?

    /// Longest wait for a frame while clients are active.
    public static let stallTimeout: Duration = .milliseconds(100)
    /// Consecutive stalls after which the link is replaced.
    public static let stallsBeforeRebuild = 3

    /// The scheduler for window-less frame work, on the main screen (no budget: budgeted batches
    /// tick on the injected ``MainWorkScheduler``).
    public static let app = FrameScheduler(name: "app", host: .screen, budget: nil)

    private static var windows: [ObjectIdentifier: WeakScheduler] = [:]

    /// `window`'s scheduler, created on first use and dropped with the window.
    public static func forWindow(_ window: NSWindow) -> FrameScheduler {
        watchSight()
        let key = ObjectIdentifier(window)
        if let scheduler = windows[key]?.value, scheduler.window === window { return scheduler }
        windows = windows.filter { $0.value.value?.window != nil }
        let scheduler = FrameScheduler(name: "window \(window.windowNumber)", host: .window(window), budget: nil)
        windows[key] = WeakScheduler(value: scheduler)
        // The window keeps its scheduler alive.
        objc_setAssociatedObject(window, &FrameScheduler.associationKey, scheduler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // The link retains its target: break the cycle when the window closes.
        scheduler.closeObserver = MainActorObservation(NSWindow.willCloseNotification, object: window) { [weak scheduler] in
            scheduler?.invalidate()
        }
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

    static var associationKey: UInt8 = 0

    enum Host {
        case screen
        case window(NSWindow)
    }

    public let name: String
    public private(set) weak var window: NSWindow?
    private let isScreenHost: Bool
    private(set) var clients: [ObjectIdentifier: FrameClient] = [:]
    /// The budgeted clients, the one that ran least recently first: a class's budget goes to them
    /// in this order, and a client that ran moves to the back, so one saturating client never
    /// keeps the others of its class from ticking (round-robin).
    private var budgetedOrder: [ObjectIdentifier] = []
    private var link: (any FrameLink)? {
        didSet { if (oldValue == nil) != (link == nil) { onLinkChange?(link != nil) } }
    }
    /// Told when the display link comes and goes (the ``MainWorkScheduler``: its link's ticks own
    /// the budget's window, and render passes are timed only while it runs).
    var onLinkChange: (@MainActor (_ exists: Bool) -> Void)?
    private let makeLinkOverride: LinkFactory?
    private let ledger: WakeupLedger
    private let stall: DemandTimer
    private var stalls = 0
    private var lastTimestamp: CFTimeInterval?
    private let mediaTime: @MainActor () -> CFTimeInterval
    /// The last link frame's timestamp (or the time the clients activated): where a stall starts.
    private var lastLinkFrame: CFTimeInterval = 0
    /// Times the stall timer was armed (each arm is one task and one cooperative-pool wake).
    public private(set) var stallTimerArms = 0
    /// The last frame stall seen (debug and tests).
    public private(set) var lastStall: FrameStall?
    private var closeObserver: MainActorObservation?
    /// The app's one window-occlusion observer (only ``app`` holds it; FrameScheduler+Sight).
    var sightObserver: MainActorObservation?
    /// Frames delivered since creation (debug).
    public private(set) var frames: UInt64 = 0
    /// Display links made since creation (debug: a link that stays up through a backlog makes one per burst).
    public private(set) var linksMade: UInt64 = 0
    /// The budget its budgeted clients draw on: only a ``MainWorkScheduler``'s scheduler has one
    /// (and only that scheduler gets budgeted clients); nil for ``app`` and window schedulers.
    let budget: MainFrameBudget?

    init(name: String, host: Host, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
         mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
         makeLink: LinkFactory? = nil, budget: MainFrameBudget?) {
        self.budget = budget
        self.mediaTime = mediaTime
        self.name = name
        switch host {
        case .screen: isScreenHost = true
        case .window(let window):
            isScreenHost = false
            self.window = window
        }
        self.ledger = ledger
        self.makeLinkOverride = makeLink
        stall = DemandTimer(owner: "FrameScheduler.stall", clock: clock, ledger: ledger)
        super.init()
    }

    /// A scheduler with a fake link (tests; budgeted work: ``MainWorkScheduler/testing(budget:clock:ledger:makeLink:)``).
    /// `clock` runs the stall timer; `mediaTime` stands in for `CACurrentMediaTime`, the timebase of frame timestamps.
    public static func testing(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                               mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                               makeLink: @escaping LinkFactory) -> FrameScheduler {
        FrameScheduler(name: "test", host: .screen, clock: clock, ledger: ledger, mediaTime: mediaTime, makeLink: makeLink, budget: nil)
    }

    /// Owners of the clients that are ticking now.
    public var activeClients: [String] {
        clients.values.filter(\.isActive).map(\.owner).sorted()
    }

    public var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// A display link exists (only while clients are active).
    public var hasLink: Bool { link != nil }

    // MARK: Clients

    func activate(_ client: FrameClient) {
        // A window out of sight gets no animation frames: the animation ends now (FrameScheduler+Sight).
        if client.isAnimation, isOutOfSight { return settle(client) }
        let id = ObjectIdentifier(client)
        clients[id] = client
        if client.workClass.isBudgeted, !budgetedOrder.contains(id) { budgetedOrder.append(id) }
        guard let link = link ?? makeLink() else {
            // No screen (headless launch): tick once on the next turn.
            // task-owner: one hop; the client deactivates or re-arms on its tick
            Task { @MainActor [weak self] in self?.frameDidFire(timestamp: nil) }
            return
        }
        if link.isPaused {
            lastTimestamp = nil
            link.isPaused = false
        }
        if !stall.isScheduled { lastLinkFrame = mediaTime() }
        armStall()
    }

    func deactivate(_ client: FrameClient) {
        drop(ObjectIdentifier(client))
        if clients.isEmpty { pause() }
    }

    func drop(_ id: ObjectIdentifier) {
        clients[id] = nil
        budgetedOrder.removeAll { $0 == id }
    }

    /// Drops the link while idle: an idle window holds no display link at
    /// all (and no link -> scheduler retain cycle); the next client makes a
    /// new one.
    func pause() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        stall.cancel()
        stalls = 0
    }

    /// Drops the link and every client (the window closed).
    public func invalidate() {
        for client in clients.values { client.detach() }
        clients.removeAll()
        budgetedOrder.removeAll()
        stall.cancel()
        link?.invalidate()
        link = nil
        closeObserver = nil
    }

    // MARK: Frames

    private func makeLink() -> (any FrameLink)? {
        let made: (any FrameLink)?
        if let makeLinkOverride {
            made = makeLinkOverride(self)
        } else if !isScreenHost, let window {
            // concurrency-allow: the sanctioned display link (one per window)
            let display = window.displayLink(target: self, selector: #selector(tick(_:)))
            display.preferredFrameRateRange = Self.motionRange
            display.add(to: .main, forMode: .common)
            made = display
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            // concurrency-allow: the sanctioned display link (window-less work)
            let display = screen.displayLink(target: self, selector: #selector(tick(_:)))
            display.preferredFrameRateRange = Self.motionRange
            display.add(to: .main, forMode: .common)
            made = display
        } else {
            made = nil
        }
        if made != nil { linksMade += 1 }
        link = made
        return made
    }

    /// Springs step every display frame: 120 Hz on ProMotion (never below 80), the display's rate elsewhere.
    private static let motionRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    @objc private func tick(_ link: CADisplayLink) {
        frameDidFire(timestamp: link.timestamp, refreshInterval: link.targetTimestamp - link.timestamp)
    }

    private func armStall(after delay: Duration = FrameScheduler.stallTimeout) {
        guard !stall.isScheduled else { return }
        stallTimerArms += 1
        stall.schedule(after: delay) { @MainActor [weak self] in self?.stallTimerFired() }
    }

    /// Half a millisecond of slack: a timer that fires on its deadline is not early by float rounding.
    private static let stallSlack: CFTimeInterval = 0.0005

    private func stallTimerFired() {
        guard !clients.isEmpty else { return }
        let sinceFrame = mediaTime() - lastLinkFrame
        let timeout = Double(Self.stallTimeout.components.seconds) + Double(Self.stallTimeout.components.attoseconds) / 1e18
        guard sinceFrame + Self.stallSlack >= timeout else {
            // A frame came since the timer was armed: wait out the rest of the timeout from it.
            armStall(after: .seconds(timeout - sinceFrame))
            return
        }
        frameStalled()
    }

    private func frameStalled() {
        stalls += 1
        if stalls >= Self.stallsBeforeRebuild {
            stalls = 0
            link?.invalidate()
            link = nil
        }
        lastStall = FrameStall(startedAt: lastLinkFrame, detectedAt: mediaTime())
        ledger.record("FrameScheduler.\(name)", reason: "stalled frame")
        deliver(timestamp: nil, refreshInterval: nil)
        guard !clients.isEmpty else { return pause() }
        (link ?? makeLink())?.isPaused = false
        armStall()
    }

    /// One display frame (the link's tick; tests call it directly).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        lastLinkFrame = timestamp ?? mediaTime()
        stalls = 0
        deliver(timestamp: timestamp, refreshInterval: refreshInterval)
        if clients.isEmpty { pause() } else { armStall() }
    }

    private func deliver(timestamp: CFTimeInterval?, refreshInterval: Double?) { // perf-hot: 0.5ms frame-tick (every frame)
        frames &+= 1
        let now = timestamp ?? CACurrentMediaTime()
        // The first frame after the link was idle has no previous one: it steps by the display's own refresh
        // period (one frame of motion, as every frame after it), not 1/60 s, which put the first moving frame of
        // every animation from rest two refreshes along its curve at 120 Hz. A synthesized frame has none: 1/60.
        let firstElapsed = refreshInterval.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? (1.0 / 60.0)
        let elapsed = lastTimestamp.map { now - $0 } ?? firstElapsed
        lastTimestamp = now
        let tick = FrameTick(timestamp: now, elapsed: min(max(elapsed, 1.0 / 240.0), 1.0 / 30.0),
                             rawElapsed: elapsed, refreshInterval: refreshInterval)
        // Visible motion (not batch work) explains CPU use to the busy watchdog.
        if clients.values.contains(where: { $0.isActive && $0.isAnimation }) {
            ExpectedActivity.shared.note(.animationFrame)
        }
        // Clients activated during this frame tick next frame. Frame-locked clients first, every
        // frame; then (only on the scheduler that holds the budget) the budgeted batches in class
        // order, each only while its class may run (a held one stays active and ticks next frame:
        // input pending, or the class's budget spent).
        let ticking = clients.values.filter(\.isActive)
        let order = budgetedOrder
        budget?.beginFrame(timestamp: timestamp, refreshInterval: refreshInterval)
        let outOfSight = isOutOfSight
        for client in ticking where !client.workClass.isBudgeted {
            // A window that went out of sight between frames: its animations end, the rest tick.
            if outOfSight, client.isAnimation { end(client) } else { fire(client, tick) }
        }
        guard let budget else { return }
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

    private func fire(_ client: FrameClient, _ tick: FrameTick) {
        ledger.record(client.owner, reason: "frame")
        if !client.fire(tick) { drop(ObjectIdentifier(client)) }
    }

    private struct WeakScheduler {
        weak var value: FrameScheduler?
    }
}
