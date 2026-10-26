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
@MainActor
public final class FrameScheduler: NSObject {
    /// Makes a test scheduler's fake link (``testing(clock:ledger:mediaTime:makeLink:)``).
    public typealias LinkFactory = @MainActor (FrameScheduler) -> (any FrameLink)?

    /// Longest wait for a frame while clients are active.
    public static let stallTimeout: Duration = DisplayClock.stallTimeout
    /// Consecutive stalls after which the link is replaced.
    public static let stallsBeforeRebuild = DisplayClock.stallsBeforeRebuild

    /// The scheduler for window-less frame work, on the main display (no budget: budgeted batches
    /// tick on the injected ``MainWorkScheduler``).
    public static let app = FrameScheduler(name: "app", host: .screen, budget: nil)

    private static var windows: [ObjectIdentifier: WeakScheduler] = [:]
    private static var attachedDisplays: DisplayClock?

    /// The display clock ``app`` and the window schedulers subscribe to: the one the composition root
    /// attached (``attach(_:)``) and shares with its ``MainWorkScheduler``; without one (tools,
    /// tests), a system clock made on first use.
    public static var appDisplays: DisplayClock {
        if let attachedDisplays { return attachedDisplays }
        let made = DisplayClock()
        attachedDisplays = made
        return made
    }

    /// Makes `displays` the clock of ``app`` and every window scheduler (the composition root, before
    /// the first window opens). A scheduler subscribed now stays on its old clock until it goes idle.
    public static func attach(_ displays: DisplayClock) {
        attachedDisplays = displays
    }

    /// `window`'s scheduler, created on first use and dropped with the window.
    public static func forWindow(_ window: NSWindow) -> FrameScheduler {
        let key = ObjectIdentifier(window)
        if let scheduler = windows[key]?.value, scheduler.window === window { return scheduler }
        windows = windows.filter { $0.value.value?.window != nil }
        let scheduler = FrameScheduler(name: "window \(window.windowNumber)", host: .window(window), budget: nil)
        windows[key] = WeakScheduler(value: scheduler)
        // The window keeps its scheduler alive.
        objc_setAssociatedObject(window, &FrameScheduler.associationKey, scheduler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // A subscribed scheduler is held by its display: let go of it when the window closes.
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

    private static var associationKey: UInt8 = 0

    enum Host {
        case screen
        case window(NSWindow)
    }

    public let name: String
    public private(set) weak var window: NSWindow?
    private let isScreenHost: Bool
    private var clients: [ObjectIdentifier: FrameClient] = [:]
    /// The budgeted clients, the one that ran least recently first: a class's budget goes to them
    /// in this order, and a client that ran moves to the back, so one saturating client never
    /// keeps the others of its class from ticking (round-robin).
    private var budgetedOrder: [ObjectIdentifier] = []
    /// The clock this scheduler subscribes to; nil: ``appDisplays``, read when it subscribes.
    private let ownDisplays: DisplayClock?
    /// The clock and display this scheduler last subscribed to (kept after it leaves, for its stall
    /// stats); ``isSubscribed`` says whether it ticks on that display now.
    private var display: (clock: DisplayClock, id: CGDirectDisplayID)?
    private var isSubscribed = false
    /// It subscribed to a display that has a link (a headless one ticks on the stall deadline only).
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
    private var closeObserver: MainActorObservation?
    /// Frames delivered since creation (debug).
    public private(set) var frames: UInt64 = 0
    /// Display links this scheduler's subscribing made since creation (debug: a scheduler that stays
    /// subscribed through a backlog makes one per burst; joining a display that has a link makes none).
    public private(set) var linksMade: UInt64 = 0
    /// The budget its budgeted clients draw on: only a ``MainWorkScheduler``'s scheduler has one
    /// (and only that scheduler gets budgeted clients); nil for ``app`` and window schedulers.
    let budget: MainFrameBudget?

    /// - Parameter displays: The clock to subscribe to; nil: ``appDisplays``.
    init(name: String, host: Host, displays: DisplayClock? = nil, clock: any Clock<Duration> = ContinuousClock(),
         ledger: WakeupLedger = .shared, budget: MainFrameBudget?) {
        self.budget = budget
        self.name = name
        switch host {
        case .screen: isScreenHost = true
        case .window(let window):
            isScreenHost = false
            self.window = window
        }
        ownDisplays = displays
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

    /// Its display's link exists and runs, and this scheduler ticks on it.
    public var isRunning: Bool { subscribed.map { $0.clock.isRunning($0.id) } ?? false }

    /// This scheduler's continuous input, coalesced to its frames and delivered before its frame
    /// clients (made on first use; dropped with the scheduler's window).
    public var input: FrameInputCoalescer {
        if let madeInput { return madeInput }
        let made = FrameInputCoalescer(scheduler: self, clock: clock, ledger: ledger)
        madeInput = made
        return made
    }

    /// A display link ticks this scheduler (only while clients are active).
    public var hasLink: Bool { subscribed.map { $0.clock.hasLink($0.id) } ?? false }

    /// The clock this scheduler subscribes to (debug.wakeups reads its live links).
    public var displayClock: DisplayClock { ownDisplays ?? Self.appDisplays }

    /// Times its display's stall timer was armed (each arm is one task and one cooperative-pool wake).
    public var stallTimerArms: Int { display.map { $0.clock.stallTimerArms(on: $0.id) } ?? 0 }
    /// The last frame stall its display saw (debug and tests).
    public var lastStall: FrameStall? { display.flatMap { $0.clock.lastStall(on: $0.id) } }

    /// The display it ticks on now.
    private var subscribed: (clock: DisplayClock, id: CGDirectDisplayID)? { isSubscribed ? display : nil }

    /// True for the ``MainWorkScheduler``'s scheduler: its budgeted classes tick last on its display.
    var holdsBudget: Bool { budget != nil }

    // MARK: Clients

    func activate(_ client: FrameClient) {
        let key = ObjectIdentifier(client)
        clients[key] = client
        if client.workClass.isBudgeted, !budgetedOrder.contains(key) { budgetedOrder.append(key) }
        guard !isSubscribed else { return }
        let displays = displayClock
        let linksBefore = displays.linksMade
        lastTimestamp = nil
        let id = displays.subscribe(self, window: isScreenHost ? nil : window)
        display = (displays, id)
        isSubscribed = true
        if displays.linksMade != linksBefore { linksMade += 1 }
        ticksOnLink = displays.hasLink(id)
    }

    func deactivate(_ client: FrameClient) {
        drop(ObjectIdentifier(client))
        if clients.isEmpty { pause() }
    }

    private func drop(_ id: ObjectIdentifier) {
        clients[id] = nil
        budgetedOrder.removeAll { $0 == id }
    }

    /// Leaves the display while idle: an idle window holds no subscription (and its display drops
    /// the link once nobody else ticks on it); the next client subscribes again.
    private func pause() {
        lastTimestamp = nil
        guard let subscribed else { return }
        isSubscribed = false
        ticksOnLink = false
        subscribed.clock.unsubscribe(self, from: subscribed.id)
    }

    /// Drops the subscription and every client (the window closed).
    public func invalidate() {
        madeInput?.invalidate()
        madeInput = nil
        for client in clients.values { client.detach() }
        clients.removeAll()
        budgetedOrder.removeAll()
        pause()
        closeObserver = nil
    }

    // MARK: Frames

    /// One display frame (tests call it directly): on its display every scheduler there ticks; a
    /// scheduler without a display (headless) ticks alone.
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        if let subscribed {
            subscribed.clock.displayDidFire(subscribed.id, timestamp: timestamp, refreshInterval: refreshInterval)
            return
        }
        let tick = beginFrame(timestamp: timestamp, refreshInterval: refreshInterval)
        deliverFrameLocked(tick)
        deliverBudgeted(tick)
        endFrame()
    }

    /// Starts this scheduler's part of a frame: its tick (with its own elapsed time) and, on the
    /// budget holder, the budget's frame window.
    func beginFrame(timestamp: CFTimeInterval?, refreshInterval: Double?) -> FrameTick {
        frames &+= 1
        let now = timestamp ?? CACurrentMediaTime()
        let elapsed = lastTimestamp.map { now - $0 } ?? (1.0 / 60.0)
        lastTimestamp = now
        // Visible motion (not batch work) explains CPU use to the busy watchdog.
        if clients.values.contains(where: { $0.isActive && $0.isAnimation }) {
            ExpectedActivity.shared.note(.animationFrame)
        }
        budget?.beginFrame(timestamp: timestamp, refreshInterval: refreshInterval)
        return FrameTick(timestamp: now, elapsed: min(max(elapsed, 1.0 / 240.0), 1.0 / 30.0),
                         rawElapsed: elapsed, refreshInterval: refreshInterval)
    }

    /// The frame-locked clients, every frame: the input stage first (the window's
    /// FrameInputCoalescer), so the frame clients see this frame's input. Clients activated during
    /// this frame tick next frame.
    func deliverFrameLocked(_ tick: FrameTick) {
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
