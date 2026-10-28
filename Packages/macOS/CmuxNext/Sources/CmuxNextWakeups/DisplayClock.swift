public import AppKit
public import CmuxNextSignposts
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
/// budgeted classes, which get what is left of the frame. A window that is occluded or miniaturized
/// gets a link tick only once per ``stallTimeout``, and a display whose subscribers are all such
/// windows stops its link and ticks them on the stall deadline (Chrome stops BeginFrames to an
/// occluded window: `content/browser/renderer_host/render_widget_host_view_mac.mm`, `WasOccluded`).
///
/// A display link stops firing while the displays sleep and when its screen goes away, yet clients
/// such as the daemon mirror must keep moving. So while a display has subscribers one stall deadline
/// runs for it: when no frame came in time its subscribers tick anyway, and after repeated stalls the
/// link is rebuilt. Frames do not touch the deadline (a new timer task per frame cost two
/// cooperative-pool wakes a frame): when it fires after a frame came, it is armed again for the rest
/// of the timeout from that frame. A window dragged to another screen moves at once (its
/// ``WindowScreenFamily``). Each time the deadline fires, every subscriber of the display also
/// resolves its display again and moves there when it changed: a window whose move was missed,
/// a screen unplugged, the main display changed (Chrome's `DisplayLinkMac` consumers register on the
/// link of the display they are on now, `ui/display/mac/display_link_mac.h`). So a display whose
/// screen went away never keeps its subscribers on the deadline's 10 Hz.
///
/// With a ``VSyncHub`` (feature `vsyncHub`), the hub holds each display's only link on the display's
/// vsync thread, and this clock is one of its subscribers: each vsync reaches main as one coalesced
/// post, at most one pending (``VSyncHub/mainLink(display:onTick:)``; Chrome's `VSyncCallbackMac`
/// posting to the thread that registered it, `ui/display/mac/display_link_mac.mm`). A stall rebuild
/// then rebuilds the hub's link of the display, which its off-main subscribers tick on too. Without
/// a hub (the default until threading-model.md's VSyncHub row records the hop measurement), the
/// clock makes a link on the main run loop per display.
///
/// ```swift
/// // The composition root builds the app's clock and installs it:
/// let displays = DisplayClock()
/// let mainWork = MainWorkScheduler(budget: budget, displays: displays, wakeUps: mainWakeUps)
/// FrameScheduler.install(displays: displays, energy: mainWork.energy)
/// displays.hub = features.isEnabled(.vsyncHub) ? VSyncHub() : nil // at launch
///
/// // A test counts links with a fake factory and fires frames by hand:
/// let displays = DisplayClock(makeLink: { _, _ in FakeLink() }, displayOf: { _ in 1 })
/// displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 60)
/// ```
@MainActor
public final class DisplayClock {
    /// Makes the link of `display` that ticks `clock` (``displayDidFire(_:timestamp:refreshInterval:targetTimestamp:)``);
    /// nil when the display is gone. A fake in tests.
    public typealias LinkFactory = @MainActor (_ display: CGDirectDisplayID, _ clock: DisplayClock) -> (any FrameLink)?
    /// The display a window is on (nil: the main display); nil when there is no screen at all.
    public typealias DisplayResolver = @MainActor (_ window: NSWindow?) -> CGDirectDisplayID?
    /// Whether a person can see any of `window` (not occluded, not miniaturized).
    public typealias VisibilityResolver = @MainActor (_ window: NSWindow) -> Bool

    /// Longest wait for a frame while a display has subscribers.
    public static let stallTimeout: Duration = .milliseconds(100)
    /// Consecutive stalls after which a display's link is replaced.
    public static let stallsBeforeRebuild = 3
    /// The slowest a link runs, whatever its clients ask: two frames per ``stallTimeout``, so a
    /// link that runs is never taken for stalled (a 5 Hz link would trip the deadline every frame).
    public static let slowestLinkHertz = Float(2 / stallSeconds)
    /// Consecutive link frames a lower rate must hold before the link is lowered to it; a higher
    /// rate applies at once. Chrome's `FrameRateDecider` toggles the display interval the same way
    /// (`kMinNumOfFramesToToggleInterval`, components/viz/service/display/frame_rate_decider.cc), so a
    /// spring or a scroll that starts soon after the last one ended never finds the link slowed.
    public static let framesBeforeLowering = 60

    /// The injected link factory (tests); nil: the hub's main links, or main-run-loop links.
    private let makeLink: LinkFactory?
    private let displayOf: DisplayResolver
    private let isVisible: VisibilityResolver
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let mediaTime: @MainActor () -> CFTimeInterval
    /// The hub whose display threads hold this clock's links (nil: main-run-loop links). Set at
    /// launch (feature `vsyncHub`); a change moves every link there is to the new source.
    public var hub: VSyncHub? {
        didSet {
            guard hub !== oldValue else { return }
            for display in displays.values { relink(display) }
        }
    }
    private var displays: [CGDirectDisplayID: Display] = [:]
    /// Writes each link tick's `frame.tick` and the key flows' `frame.present_estimate` while a
    /// recording turns the frame category on (p09-observability 037); a flow waiting on a display whose
    /// link is idle gets one tick of it (``presentNeedsFrame(_:)``).
    public let presents: FramePresentEstimate

    /// Display links made since creation, stall rebuilds included (debug.wakeups).
    public private(set) var linksMade: UInt64 = 0

    /// The display links ``FrameScheduler/app`` and the window schedulers on this clock tick on, and
    /// their frames: the ``MainWorkScheduler`` waits for none to run before a long idle period, and
    /// their frames open short ones. The budgeted scheduler does not report here.
    public let unbudgetedLinks: UnbudgetedFrameLinks

    /// Each display's link runs at the highest ``FrameClient/rate`` armed on it (feature
    /// `frameRateClasses`); false: links run at ``FrameRate/motion`` but for saver-capped ambient clients.
    public var followsClientRates: Bool {
        didSet {
            guard followsClientRates != oldValue else { return }
            for display in displays.values { applyRate(display, .setting) }
        }
    }

    /// - Parameters:
    ///   - hub: The vsync hub whose display threads hold the links (``hub``); nil: main-run-loop links.
    ///   - makeLink: Makes a display's link; nil: `hub`'s main link of that display, or without a hub a
    ///     `CADisplayLink` of the `NSScreen` with that number on the main run loop.
    ///   - displayOf: Resolves a window's display; nil: the window's screen, else the main screen.
    ///   - isVisible: Whether a window can be seen; nil: not miniaturized, the app not hidden, and,
    ///     while the window is on screen, some part of it visible.
    ///   - clock: Runs the stall deadlines.
    ///   - ledger: Where stalls and deadlines are recorded.
    ///   - mediaTime: Stands in for `CACurrentMediaTime`, the timebase of frame timestamps.
    ///   - followsClientRates: The links run at their clients' rates (``followsClientRates``).
    ///   - presents: The frame trace points of its ticks (``presents``); nil: one on the app's trace runtime.
    public init(hub: VSyncHub? = nil, makeLink: LinkFactory? = nil, displayOf: DisplayResolver? = nil,
                isVisible: VisibilityResolver? = nil, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                followsClientRates: Bool = false, presents: FramePresentEstimate? = nil) {
        self.presents = presents ?? FramePresentEstimate()
        unbudgetedLinks = UnbudgetedFrameLinks()
        self.followsClientRates = followsClientRates
        self.hub = hub
        self.makeLink = makeLink
        self.displayOf = displayOf ?? { window in DisplayClock.systemDisplay(window) }
        self.isVisible = isVisible ?? { window in DisplayClock.systemIsVisible(window) }
        self.clock = clock
        self.ledger = ledger
        self.mediaTime = mediaTime
        self.presents.onNeedsFrame = { [weak self] display in self?.presentNeedsFrame(display) }
    }

    /// Links alive now, over every display (0 at idle).
    public var liveLinks: Int { displays.values.filter { $0.link != nil }.count }

    /// The names of the schedulers subscribed to `display`, in the order they subscribed.
    public func subscribers(on display: CGDirectDisplayID) -> [String] {
        displays[display]?.subscribers.map(\.name) ?? []
    }

    /// `display` has a link now.
    public func hasLink(_ display: CGDirectDisplayID) -> Bool { displays[display]?.link != nil }

    /// The media time now (`CACurrentMediaTime`, or the injected one): the time of a frame with no link time.
    func now() -> CFTimeInterval { mediaTime() }

    /// `display`'s link exists and is not paused.
    public func isRunning(_ display: CGDirectDisplayID) -> Bool {
        displays[display]?.link.map { !$0.isPaused } ?? false
    }

    /// Times `display`'s stall timer was armed (each arm is one task and one cooperative-pool wake).
    public func stallTimerArms(on display: CGDirectDisplayID) -> Int { displays[display]?.stallTimerArms ?? 0 }

    /// The last frame stall `display` saw.
    public func lastStall(on display: CGDirectDisplayID) -> FrameStall? { displays[display]?.lastStall }

    /// The rate `display`'s link was last asked for; nil while the display has no link.
    public func frameRate(on display: CGDirectDisplayID) -> FrameRate? { displays[display]?.rate }

    /// The last link frame of the key window's display (``newestFrame(for:)`` with no window): the grid an action's
    /// estimated present and a late motion commit are placed on, as the person acts in and watches the key window.
    public func newestFrame() -> DisplayFrameSample? { newestFrame(for: nil) }

    /// The last link frame of the display `window` is on (nil: the key window's), with whether that display's link
    /// runs now: the vsync grid ``DisplayFrameSample`` places a time on, as Chrome's compositor reads the
    /// `BeginFrameSource` of its own display (ui/display/mac/display_link_mac.h, one link per display). Nil when
    /// that display had no link frame yet. With no screen at all, the newest frame of any display, never marked
    /// running (its phase is another display's). Reads only: no link is made or resumed, and a display keeps its
    /// last frame when its link stops.
    public func newestFrame(for window: NSWindow?) -> DisplayFrameSample? {
        if let id = displayOf(window) {
            guard let display = displays[id], let vsync = display.lastVsync else { return nil }
            return DisplayFrameSample(timestamp: vsync.timestamp, interval: vsync.interval,
                                      linkRunning: display.link.map { !$0.isPaused } ?? false)
        }
        let newest = displays.values.compactMap { $0.lastVsync }.max { $0.timestamp < $1.timestamp }
        return newest.flatMap { DisplayFrameSample(timestamp: $0.timestamp, interval: $0.interval, linkRunning: false) }
    }

    // MARK: Subscribers

    /// Subscribes `scheduler` to the display of its window (the main display for a screen host;
    /// ``noDisplay`` when there is no screen) and makes sure that display's link runs. Without a link
    /// (no screen, a headless launch) its subscribers tick once on the next turn, then on the stall
    /// deadline, which retries the link and the display each time.
    func subscribe(_ scheduler: FrameScheduler) -> CGDirectDisplayID {
        let id = resolve(scheduler)
        join(scheduler, record(id))
        return id
    }

    /// The display `scheduler` is on now (``noDisplay`` when there is no screen).
    private func resolve(_ scheduler: FrameScheduler) -> CGDirectDisplayID {
        displayOf(scheduler.hostWindow) ?? Self.noDisplay
    }

    /// The display `window` is on (nil: the main display), by this clock's resolver.
    public func display(of window: NSWindow?) -> CGDirectDisplayID? { displayOf(window) }

    /// One link tick of `id` for a key flow's present, asked only while recording (``presents``): a paused
    /// link runs a frame, and an idle display gets a link that its first tick (or the stall deadline) drops.
    private func presentNeedsFrame(_ id: CGDirectDisplayID) {
        let display = record(id)
        guard let link = display.link ?? make(display) else { return }
        link.isPaused = false
        if display.subscribers.isEmpty { arm(display) }
    }

    private func join(_ scheduler: FrameScheduler, _ display: Display) {
        if !display.subscribers.contains(where: { $0 === scheduler }) { display.subscribers.append(scheduler) }
        if !display.stall.isScheduled { display.lastFrame = mediaTime() }
        if let link = display.link ?? make(display) {
            if link.isPaused { link.isPaused = false }
        } else if !display.linklessTickQueued {
            display.linklessTickQueued = true
            let id = display.id
            // task-owner: one hop; the subscribers leave or keep ticking on the stall deadline
            // main-hop-allow: the frame clock's own tick for a display with no link; p06 section A: a frame source is never queued behind the classes it drives
            Task { @MainActor [weak self] in self?.linklessTick(id) }
        }
        applyRate(display)
        arm(display)
    }

    /// Moves `scheduler`, subscribed to `id`, to the display it is on now if that changed (its window
    /// went to another screen, or its screen went away), and tells it.
    func resubscribe(_ scheduler: FrameScheduler, from id: CGDirectDisplayID) {
        let now = resolve(scheduler)
        guard now != id, let old = displays[id], old.subscribers.contains(where: { $0 === scheduler }) else { return }
        old.subscribers.removeAll { $0 === scheduler }
        join(scheduler, record(now))
        scheduler.displayDidChange(to: now, hasLink: hasLink(now))
        if old.subscribers.isEmpty { idle(old) } else { applyRate(old) }
    }

    /// Every subscriber of `display` resolves its display again and moves to it.
    private func relocate(_ display: Display) {
        for scheduler in display.subscribers { resubscribe(scheduler, from: display.id) }
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
        if display.subscribers.isEmpty { idle(display) } else { applyRate(display) }
    }

    /// A subscriber of `id` armed or dropped a client of another ``FrameRate``.
    func frameRateDidChange(on id: CGDirectDisplayID) {
        guard let display = displays[id] else { return }
        applyRate(display)
    }

    // MARK: Frame rate

    /// What asked for a new rate decision.
    private enum RateTrigger {
        /// A subscriber or a client came or went.
        case clients
        /// A link frame (or a tick standing in for one): the only trigger that counts toward lowering.
        case frame
        /// ``followsClientRates`` changed: the new rate applies at once.
        case setting
    }

    /// Asks `display`'s link for the rate its subscribers need now: the highest ``FrameScheduler/linkRate``
    /// (``FrameRate/motion`` unless ``followsClientRates`` or the saver caps an ambient client) of the
    /// subscribers a person can see, or of all of them while nobody can see any. Chrome's `FrameRateDecider` counts only
    /// the frame sinks that drew (components/viz/service/display/frame_rate_decider.cc); a window
    /// nobody can see ticks on the stall deadline, not the link. A higher rate applies at once, a
    /// lower one after ``framesBeforeLowering`` frames.
    private func applyRate(_ display: Display, _ trigger: RateTrigger = .clients) {
        guard let link = display.link else { return }
        let rate = decidedRate(display)
        guard let current = display.rate else { return request(rate, display, link) }
        if rate.hertz < current.hertz, trigger != .setting {
            guard trigger == .frame else { return }
            display.framesBelowRate += 1
            guard display.framesBelowRate >= Self.framesBeforeLowering else { return }
        } else if rate.hertz > current.hertz, trigger == .clients, !link.isPaused {
            tickOnNextTurn(display)
        }
        display.framesBelowRate = 0
        if rate != current { request(rate, display, link) }
    }

    private func request(_ rate: FrameRate, _ display: Display, _ link: any FrameLink) {
        display.rate = rate
        link.requestFrameRate(Self.linkRange(rate))
    }

    /// A client that needs a faster rate armed while the link ran slower, whose next callback can
    /// still come on the slow cadence (33 ms at 30 Hz, past an input's 10 ms budget): the display
    /// ticks once on the next turn, as for a display with no link, unless its link fires first.
    private func tickOnNextTurn(_ display: Display) {
        guard !display.raiseTickQueued else { return }
        display.raiseTickQueued = true
        let id = display.id, framesBefore = display.frames
        // task-owner: one hop; the link ticks the display after it
        // main-hop-allow: the frame clock's own tick, as the linkless tick; p06 section A: a frame source is never queued behind the classes it drives
        Task { @MainActor [weak self] in self?.raiseTick(id, framesBefore: framesBefore) }
    }

    private func raiseTick(_ id: CGDirectDisplayID, framesBefore: UInt64) {
        guard let display = displays[id] else { return }
        display.raiseTickQueued = false
        guard display.frames == framesBefore, display.link != nil, !display.subscribers.isEmpty else { return }
        displayDidFire(id)
    }

    private func decidedRate(_ display: Display) -> FrameRate {
        var seen: FrameRate?, all: FrameRate?
        for scheduler in display.subscribers {
            guard let rate = scheduler.linkRate else { continue }
            if all.map({ rate.hertz > $0.hertz }) ?? true { all = rate }
            let visible = scheduler.isSeen(by: isVisible)
            if visible, seen.map({ rate.hertz > $0.hertz }) ?? true { seen = rate }
        }
        return seen ?? all ?? .motion
    }

    // MARK: Frames

    /// One frame of `display` (its link's tick; tests call it directly). A window nobody can see
    /// ticks only once its last tick is a ``stallTimeout`` old. `targetTimestamp`: when the frame is shown.
    public func displayDidFire(_ id: CGDirectDisplayID, timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil,
                               targetTimestamp: CFTimeInterval? = nil) {
        guard let display = displays[id] else { return }
        let now = timestamp ?? mediaTime()
        display.frames &+= 1
        display.lastFrame = now
        display.stalls = 0
        if let timestamp, let refreshInterval { display.lastVsync = (timestamp, refreshInterval) }
        deliver(display, timestamp: timestamp, refreshInterval: refreshInterval, targetTimestamp: targetTimestamp,
                hiddenUntil: now - Self.stallSeconds)
        guard !display.subscribers.isEmpty else { return idle(display) }
        // Only windows nobody can see are left: the link stops, they tick on the stall deadline.
        if allHidden(display) { display.link?.isPaused = true }
        // A window that became visible or hidden changes which clients count; a lower rate (client
        // rates, or a saver-capped ambient client) counts its frames here.
        if followsClientRates || display.subscribers.contains(where: { $0.ambientCap != nil }) { applyRate(display, .frame) }
        arm(display)
    }

    /// ``stallTimeout`` in seconds.
    private static let stallSeconds = Double(stallTimeout.components.seconds) + Double(stallTimeout.components.attoseconds) / 1e18

    /// - Parameter hiddenUntil: A window nobody can see ticks only if its last tick is at or before
    ///   this time; nil: every subscriber ticks (the stall deadline).
    private func deliver(_ display: Display, timestamp: CFTimeInterval?, refreshInterval: Double?, // perf-hot: 0.5ms frame-tick (every frame)
                         targetTimestamp: CFTimeInterval? = nil, hiddenUntil: CFTimeInterval?) {
        // frame.tick and the waiting flows' presents, for link ticks while recording: one load when not.
        if presents.isRecording, let timestamp {
            presents.frameDidTick(display: display.id, timestamp: timestamp,
                                  target: targetTimestamp ?? timestamp + (refreshInterval ?? FrameTick.defaultRefreshInterval))
        }
        // Schedulers that subscribe during this tick tick next frame; one that leaves during it
        // (its window closed) gets nothing more.
        // A scheduler that just came from another display skips a frame that starts or is shown no
        // later than its last one (``FrameScheduler/takesTick(timestamp:refreshInterval:targetTimestamp:)``).
        let ticking = display.subscribers.compactMap { scheduler -> (FrameScheduler, FrameTick)? in
            guard let pace = pace(scheduler, hiddenUntil: hiddenUntil),
                  scheduler.takesTick(timestamp: timestamp, refreshInterval: refreshInterval, targetTimestamp: targetTimestamp)
            else { return nil }
            return (scheduler, scheduler.beginFrame(timestamp: timestamp, refreshInterval: refreshInterval,
                                                    targetTimestamp: targetTimestamp, offLink: pace != .link, seen: pace != .hidden))
        }
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

    /// What paces a scheduler's ticks: every frame of the display's `link`; the `stall` deadline (no link
    /// frame came in time) of a window someone sees, or of a window-less scheduler; the stall rate of a
    /// `hidden` window, one nobody can see.
    private enum Pace { case link, stall, hidden }

    /// Whether `scheduler` ticks in this frame, and at what pace (nil: not this frame). A window nobody
    /// can see ticks at the stall rate, not the display's (R6: hidden and occluded cost nothing); the
    /// app and budgeted schedulers always tick.
    private func pace(_ scheduler: FrameScheduler, hiddenUntil: CFTimeInterval?) -> Pace? {
        guard let hiddenUntil else { return scheduler.isSeen(by: isVisible) ? .stall : .hidden }
        guard !scheduler.isSeen(by: isVisible) else { return .link }
        let due = scheduler.lastTickTimestamp.map { $0 <= hiddenUntil + Self.stallSlack } ?? true
        return due ? .hidden : nil
    }

    /// Every subscriber of `display` is a window nobody can see.
    private func allHidden(_ display: Display) -> Bool {
        !display.subscribers.isEmpty && display.subscribers.allSatisfy { !$0.isSeen(by: isVisible) }
    }

    private func record(_ id: CGDirectDisplayID) -> Display {
        if let display = displays[id] { return display }
        // timer-class-allow: the frame clock's own stall deadline, an unposted scheduler timer (p06 section A)
        let display = Display(id: id, stall: DemandTimer(owner: "DisplayClock.stall", clock: clock, ledger: ledger))
        displays[id] = display
        return display
    }

    @discardableResult
    private func make(_ display: Display) -> (any FrameLink)? {
        let made = newLink(display.id)
        if made != nil { linksMade += 1 }
        setLink(display, made)
        return made
    }

    private func newLink(_ id: CGDirectDisplayID) -> (any FrameLink)? {
        if let makeLink { return makeLink(id, self) }
        if let hub { return Self.hubLink(hub, id, self) }
        return Self.systemLink(id, self)
    }

    /// Replaces `display`'s link after repeated stalls. A hub link rebuilds the hub's link of the
    /// display in place, so the hub's other subscribers there tick on the new link too; any other
    /// link (or a hub that found no screen) is replaced by a new one.
    private func rebuildLink(_ display: Display) -> (any FrameLink)? {
        if let link = display.link as? VSyncHub.MainLink, link.relink() {
            linksMade += 1
            return link
        }
        display.link?.invalidate()
        return make(display)
    }

    /// Moves `display`'s link, if it has one, to the clock's link source now (``hub`` changed); it
    /// stays paused if it was.
    private func relink(_ display: Display) {
        guard let old = display.link else { return }
        let paused = old.isPaused
        old.invalidate()
        make(display)?.isPaused = paused
        applyRate(display, .setting)
    }

    /// Sets `display`'s link and tells its subscribers whether a link ticks them now.
    private func setLink(_ display: Display, _ link: (any FrameLink)?) {
        display.link = link
        display.rate = nil
        display.framesBelowRate = 0
        for scheduler in display.subscribers { scheduler.displayLinkDidChange(exists: link != nil) }
    }

    /// Drops `display`'s link while nobody subscribes: no link, no stall deadline, no wakeups.
    private func idle(_ display: Display) {
        display.link?.invalidate()
        setLink(display, nil)
        display.stall.cancel()
        display.stalls = 0
    }

    // MARK: Stalls

    private func arm(_ display: Display, after delay: Duration = DisplayClock.stallTimeout) {
        guard !display.stall.isScheduled else { return }
        display.stallTimerArms += 1
        let id = display.id
        display.stall.scheduleOnMain(after: delay) { [weak self] in self?.stallTimerFired(id) }
    }

    /// Half a millisecond of slack: a timer that fires on its deadline is not early by float rounding.
    private static let stallSlack: CFTimeInterval = 0.0005

    /// `id`'s stall deadline passed (its timer; tests call it directly). Its subscribers that are on
    /// another display now move there first.
    func stallTimerFired(_ id: CGDirectDisplayID) {
        guard let display = displays[id] else { return }
        // A link no subscriber holds (a present's one tick that never came) goes.
        guard !display.subscribers.isEmpty else { return idle(display) }
        relocate(display)
        guard !display.subscribers.isEmpty else { return }
        let sinceFrame = mediaTime() - display.lastFrame
        guard sinceFrame + Self.stallSlack >= Self.stallSeconds else {
            // A frame came since the timer was armed: wait out the rest of the timeout from it.
            arm(display, after: .seconds(Self.stallSeconds - sinceFrame))
            return
        }
        if let link = display.link, link.isPaused {
            // The link was stopped because nobody could see this display's windows: they tick on the
            // deadline, and the link runs again once one of them can be seen.
            deliver(display, timestamp: nil, refreshInterval: nil, hiddenUntil: nil)
            guard !display.subscribers.isEmpty else { return idle(display) }
            if !allHidden(display) {
                link.isPaused = false
                display.lastFrame = mediaTime()
            }
            arm(display)
            return
        }
        display.stalls += 1
        let rebuild = display.stalls >= Self.stallsBeforeRebuild
        if rebuild { display.stalls = 0 }
        display.lastStall = FrameStall(startedAt: display.lastFrame, detectedAt: mediaTime())
        for scheduler in display.subscribers { ledger.record("FrameScheduler.\(scheduler.name)", reason: "stalled frame") }
        deliver(display, timestamp: nil, refreshInterval: nil, hiddenUntil: nil)
        guard !display.subscribers.isEmpty else { return idle(display) }
        // No link (the display has no screen yet): its subscribers tick on the deadline and retry.
        (rebuild ? rebuildLink(display) : display.link ?? make(display))?.isPaused = false
        arm(display)
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
        /// The rate its link was last asked for; nil while it has no link or a new one.
        var rate: FrameRate?
        /// Consecutive frames its decided rate stayed below ``rate`` (``framesBeforeLowering``).
        var framesBelowRate = 0
        /// Frames delivered by ``displayDidFire(_:timestamp:refreshInterval:targetTimestamp:)``.
        var frames: UInt64 = 0
        /// A next-turn tick is queued for a client that raised the rate (``tickOnNextTurn(_:)``).
        var raiseTickQueued = false
        /// The last link frame's vsync time and refresh period (``DisplayClock/newestFrame(for:)``), kept when the link stops.
        var lastVsync: (timestamp: CFTimeInterval, interval: Double)?
        /// A next-turn tick is queued for subscribers that came while the display had no link.
        var linklessTickQueued = false

        init(id: CGDirectDisplayID, stall: DemandTimer) {
            self.id = id
            self.stall = stall
        }
    }

    // MARK: System links

    private static func systemLink(_ id: CGDirectDisplayID, _ clock: DisplayClock) -> (any FrameLink)? {
        guard let screen = NSScreen.screens.first(where: { number(of: $0) == id }) else { return nil }
        let target = LinkTarget(clock: clock, display: id)
        // The one sanctioned display link: one per display, shared by every scheduler on it.
        let link = screen.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        // Springs step every display frame until the clients ask for less (applyRate).
        link.preferredFrameRateRange = FrameRate.motion.range
        link.add(to: .main, forMode: .common)
        return link
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
            clock?.displayDidFire(display, timestamp: link.timestamp, refreshInterval: link.targetTimestamp - link.timestamp,
                                  targetTimestamp: link.targetTimestamp)
        }
    }
}
