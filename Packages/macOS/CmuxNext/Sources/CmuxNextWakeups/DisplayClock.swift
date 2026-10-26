public import AppKit
public import QuartzCore

/// One display link per display, shared by every ``FrameScheduler`` on it (Chrome's
/// `ui/display/mac/display_link_mac.h`: `DisplayLinkMac::GetForDisplay(display_id)` returns one
/// ref-counted link per display that all consumers register on).
///
/// Windows, ``FrameScheduler/app`` and the ``MainWorkScheduler``'s budgeted scheduler subscribe to
/// their display while they have active clients. The display's link exists only while it has a
/// subscriber; the last one leaving drops it, so an idle app holds no link and has no frame wakeups.
/// This is the only code that creates a display link (`scripts/cmux-next/check-concurrency.sh`),
/// and only through its injected ``LinkFactory``.
///
/// Each tick goes out in one order: the budget holder's frame-locked clients (its input stage and the
/// daemon drains), then every other scheduler on the display (windows, app), then the budget holder's
/// budgeted classes, which get what is left of the frame.
///
/// A display link stops firing while the displays sleep, when its screen goes away, and for some
/// occluded windows, yet clients such as the daemon mirror must keep moving. So while a display has
/// subscribers one stall deadline runs for it: when no frame came in time its subscribers tick
/// anyway, and after repeated stalls the link is rebuilt. Frames do not touch the deadline (a new
/// timer task per frame cost two cooperative-pool wakes a frame): when it fires after a frame came,
/// it is armed again for the rest of the timeout from that frame.
///
/// ```swift
/// // FrameScheduler.app owns the app's clock; the composition root shares it:
/// let mainWork = MainWorkScheduler(budget: budget, displays: FrameScheduler.appDisplays)
///
/// // A test counts links with a fake factory and fires frames by hand:
/// let displays = DisplayClock(makeLink: { _, _ in FakeLink() }, displayOf: { _ in 1 })
/// displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 60)
/// ```
@MainActor
public final class DisplayClock {
    /// Makes the link of `display` that ticks `clock` (``displayDidFire(_:timestamp:refreshInterval:)``);
    /// nil when the display is gone. A fake in tests.
    public typealias LinkFactory = @MainActor (_ display: CGDirectDisplayID, _ clock: DisplayClock) -> (any FrameLink)?
    /// The display a window is on (nil: the main display); nil when there is no screen at all.
    public typealias DisplayResolver = @MainActor (_ window: NSWindow?) -> CGDirectDisplayID?

    /// Longest wait for a frame while a display has subscribers.
    public static let stallTimeout: Duration = .milliseconds(100)
    /// Consecutive stalls after which a display's link is replaced.
    public static let stallsBeforeRebuild = 3

    private let makeLink: LinkFactory
    private let displayOf: DisplayResolver
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let mediaTime: @MainActor () -> CFTimeInterval
    private var displays: [CGDirectDisplayID: Display] = [:]

    /// Display links made since creation, stall rebuilds included (debug.wakeups).
    public private(set) var linksMade: UInt64 = 0

    /// - Parameters:
    ///   - makeLink: Makes a display's link; nil: a `CADisplayLink` of the `NSScreen` with that number
    ///     on the main run loop.
    ///   - displayOf: Resolves a window's display; nil: the window's screen, else the main screen.
    ///   - clock: Runs the stall deadlines.
    ///   - ledger: Where stalls and deadlines are recorded.
    ///   - mediaTime: Stands in for `CACurrentMediaTime`, the timebase of frame timestamps.
    public init(makeLink: LinkFactory? = nil, displayOf: DisplayResolver? = nil,
                clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.makeLink = makeLink ?? { display, clock in DisplayClock.systemLink(display, clock) }
        self.displayOf = displayOf ?? { window in DisplayClock.systemDisplay(window) }
        self.clock = clock
        self.ledger = ledger
        self.mediaTime = mediaTime
    }

    /// Links alive now, over every display (0 at idle).
    public var liveLinks: Int { displays.values.filter { $0.link != nil }.count }

    /// The names of the schedulers subscribed to `display`, in the order they subscribed.
    public func subscribers(on display: CGDirectDisplayID) -> [String] {
        displays[display]?.subscribers.map(\.name) ?? []
    }

    /// `display` has a link now.
    public func hasLink(_ display: CGDirectDisplayID) -> Bool { displays[display]?.link != nil }

    /// `display`'s link exists and is not paused.
    public func isRunning(_ display: CGDirectDisplayID) -> Bool {
        displays[display]?.link.map { !$0.isPaused } ?? false
    }

    /// Times `display`'s stall timer was armed (each arm is one task and one cooperative-pool wake).
    public func stallTimerArms(on display: CGDirectDisplayID) -> Int { displays[display]?.stallTimerArms ?? 0 }

    /// The last frame stall `display` saw.
    public func lastStall(on display: CGDirectDisplayID) -> FrameStall? { displays[display]?.lastStall }

    // MARK: Subscribers

    /// Subscribes `scheduler` to the display of `window` (the main display for nil; ``noDisplay``
    /// when there is no screen) and makes sure that display's link runs. Without a link (no screen,
    /// a headless launch) its subscribers tick once on the next turn, then on the stall deadline,
    /// which retries the link each time.
    func subscribe(_ scheduler: FrameScheduler, window: NSWindow?) -> CGDirectDisplayID {
        let id = displayOf(window) ?? Self.noDisplay
        let display = record(id)
        if !display.subscribers.contains(where: { $0 === scheduler }) { display.subscribers.append(scheduler) }
        if !display.stall.isScheduled { display.lastFrame = mediaTime() }
        if let link = display.link ?? make(display) {
            if link.isPaused { link.isPaused = false }
        } else if !display.linklessTickQueued {
            display.linklessTickQueued = true
            // task-owner: one hop; the subscribers leave or keep ticking on the stall deadline
            Task { @MainActor [weak self] in self?.linklessTick(id) }
        }
        arm(display)
        return id
    }

    /// The display id of "no screen": its subscribers tick on the stall deadline only.
    public static let noDisplay: CGDirectDisplayID = 0

    private func linklessTick(_ id: CGDirectDisplayID) {
        guard let display = displays[id] else { return }
        display.linklessTickQueued = false
        guard display.link == nil, !display.subscribers.isEmpty else { return }
        displayDidFire(id)
    }

    /// Takes `scheduler` off `display`; the last subscriber leaving drops the display's link.
    func unsubscribe(_ scheduler: FrameScheduler, from id: CGDirectDisplayID) {
        guard let display = displays[id] else { return }
        display.subscribers.removeAll { $0 === scheduler }
        if display.subscribers.isEmpty { idle(display) }
    }

    // MARK: Frames

    /// One frame of `display` (its link's tick; tests call it directly).
    public func displayDidFire(_ id: CGDirectDisplayID, timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        guard let display = displays[id] else { return }
        display.lastFrame = timestamp ?? mediaTime()
        display.stalls = 0
        deliver(display, timestamp: timestamp, refreshInterval: refreshInterval)
        if display.subscribers.isEmpty { idle(display) } else { arm(display) }
    }

    private func deliver(_ display: Display, timestamp: CFTimeInterval?, refreshInterval: Double?) { // perf-hot: 0.5ms frame-tick (every frame)
        // Schedulers that subscribe during this tick tick next frame; one that leaves during it
        // (its window closed) gets nothing more.
        let ticking = display.subscribers.map { ($0, $0.beginFrame(timestamp: timestamp, refreshInterval: refreshInterval)) }
        func subscribed(_ scheduler: FrameScheduler) -> Bool { display.subscribers.contains { $0 === scheduler } }
        for (scheduler, tick) in ticking where scheduler.holdsBudget && subscribed(scheduler) {
            scheduler.deliverFrameLocked(tick)
        }
        for (scheduler, tick) in ticking where !scheduler.holdsBudget && subscribed(scheduler) {
            scheduler.deliverFrameLocked(tick)
        }
        for (scheduler, tick) in ticking where scheduler.holdsBudget && subscribed(scheduler) {
            scheduler.deliverBudgeted(tick)
        }
        for (scheduler, _) in ticking where subscribed(scheduler) {
            scheduler.endFrame()
        }
    }

    private func record(_ id: CGDirectDisplayID) -> Display {
        if let display = displays[id] { return display }
        let display = Display(id: id, stall: DemandTimer(owner: "DisplayClock.stall", clock: clock, ledger: ledger))
        displays[id] = display
        return display
    }

    private func make(_ display: Display) -> (any FrameLink)? {
        let made = makeLink(display.id, self)
        if made != nil { linksMade += 1 }
        display.link = made
        return made
    }

    /// Drops `display`'s link while nobody subscribes: no link, no stall deadline, no wakeups.
    private func idle(_ display: Display) {
        display.link?.invalidate()
        display.link = nil
        display.stall.cancel()
        display.stalls = 0
    }

    // MARK: Stalls

    private func arm(_ display: Display, after delay: Duration = DisplayClock.stallTimeout) {
        guard !display.stall.isScheduled else { return }
        display.stallTimerArms += 1
        let id = display.id
        display.stall.schedule(after: delay) { @MainActor [weak self] in self?.stallTimerFired(id) }
    }

    /// Half a millisecond of slack: a timer that fires on its deadline is not early by float rounding.
    private static let stallSlack: CFTimeInterval = 0.0005

    private func stallTimerFired(_ id: CGDirectDisplayID) {
        guard let display = displays[id], !display.subscribers.isEmpty else { return }
        let sinceFrame = mediaTime() - display.lastFrame
        let timeout = Double(Self.stallTimeout.components.seconds) + Double(Self.stallTimeout.components.attoseconds) / 1e18
        guard sinceFrame + Self.stallSlack >= timeout else {
            // A frame came since the timer was armed: wait out the rest of the timeout from it.
            arm(display, after: .seconds(timeout - sinceFrame))
            return
        }
        display.stalls += 1
        if display.stalls >= Self.stallsBeforeRebuild {
            display.stalls = 0
            display.link?.invalidate()
            display.link = nil
        }
        display.lastStall = FrameStall(startedAt: display.lastFrame, detectedAt: mediaTime())
        for scheduler in display.subscribers { ledger.record("FrameScheduler.\(scheduler.name)", reason: "stalled frame") }
        deliver(display, timestamp: nil, refreshInterval: nil)
        guard !display.subscribers.isEmpty else { return idle(display) }
        (display.link ?? make(display))?.isPaused = false
        arm(display)
    }

    // MARK: System links

    /// Springs step every display frame: 120 Hz on ProMotion (never below 80), the display's rate elsewhere.
    private static let motionRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    private static func systemLink(_ id: CGDirectDisplayID, _ clock: DisplayClock) -> (any FrameLink)? {
        guard let screen = NSScreen.screens.first(where: { number(of: $0) == id }) else { return nil }
        let target = LinkTarget(clock: clock, display: id)
        // The one sanctioned display link: one per display, shared by every scheduler on it.
        let link = screen.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        link.preferredFrameRateRange = motionRange
        link.add(to: .main, forMode: .common)
        return link
    }

    private static func systemDisplay(_ window: NSWindow?) -> CGDirectDisplayID? {
        (window?.screen ?? NSScreen.main ?? NSScreen.screens.first).flatMap(number(of:))
    }

    private static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// One display's link, its subscribers and its stall deadline.
    @MainActor
    private final class Display {
        let id: CGDirectDisplayID
        let stall: DemandTimer
        var link: (any FrameLink)?
        var subscribers: [FrameScheduler] = []
        var stalls = 0
        /// The last link frame's timestamp (or the time the first subscriber came): where a stall starts.
        var lastFrame: CFTimeInterval = 0
        var stallTimerArms = 0
        var lastStall: FrameStall?
        /// A next-turn tick is queued for subscribers that came while the display had no link.
        var linklessTickQueued = false

        init(id: CGDirectDisplayID, stall: DemandTimer) {
            self.id = id
            self.stall = stall
        }
    }

    /// The link's target: the link retains it, and it holds the clock weakly, so a link never keeps
    /// its clock alive (the clock drops the link when idle).
    @MainActor
    private final class LinkTarget: NSObject {
        private weak var clock: DisplayClock?
        private let display: CGDirectDisplayID

        init(clock: DisplayClock, display: CGDirectDisplayID) {
            self.clock = clock
            self.display = display
            super.init()
        }

        @objc func tick(_ link: CADisplayLink) {
            clock?.displayDidFire(display, timestamp: link.timestamp, refreshInterval: link.targetTimestamp - link.timestamp)
        }
    }
}
