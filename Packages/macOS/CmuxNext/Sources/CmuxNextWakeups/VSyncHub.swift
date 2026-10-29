public import AppKit
public import QuartzCore
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// What the hub needs from a display link (a fake in tests). The hub makes it on the main thread
/// through its factory and hands it to the display's hub thread; every call after that runs there.
public protocol VSyncLink: AnyObject, Sendable {
    /// Adds the link to the calling thread's run loop. The hub calls it once, on the display's hub
    /// thread, so the link's ticks run there.
    func attachToCurrentRunLoop()
    var isPaused: Bool { get set }
    func invalidate()
    /// Asks the link to fire at `range`: the fastest rate an armed subscriber of the display needs.
    func requestFrameRate(_ range: CAFrameRateRange)
}

/// A screen's `CADisplayLink` as a hub link.
// crash-allow: main makes the link and hands it over untouched; from then on only the display's hub thread calls it (attach, pause, invalidate) and its ticks run there
private final class ScreenVSyncLink: VSyncLink, @unchecked Sendable {
    private let link: CADisplayLink

    init(_ link: CADisplayLink) {
        self.link = link
    }

    func attachToCurrentRunLoop() {
        link.add(to: .current, forMode: .common)
    }

    var isPaused: Bool {
        get { link.isPaused }
        set { link.isPaused = newValue }
    }

    func invalidate() {
        link.invalidate()
    }

    func requestFrameRate(_ range: CAFrameRateRange) {
        link.preferredFrameRateRange = range
    }
}

/// The vsync thread of each display, which holds that display's only display link.
///
/// This is Chrome's design: `ui/display/mac/ca_display_link_mac.mm` adds one link per display to
/// the run loop of a presentation-priority thread, and `ui/display/mac/display_link_mac.mm`'s
/// `VSyncCallbackMac` runs each callback on the link thread or posts it to the thread that
/// registered it (`base::BindPostTaskToCurrentDefault`).
///
/// - Off-main producers (Ghostty's renderers) subscribe with a `Sendable` callback that runs on the
///   hub thread at every vsync while they are armed. A producer arms when its content changes and
///   returns ``Demand/done`` from a tick with nothing to draw, which disarms it (Chrome's
///   `SetNeedsBeginFrame`).
/// - The main thread's frame clock subscribes through ``mainLink(display:onTick:)``. Its callback
///   posts one coalesced tick to the main run loop: at most one is pending, and a newer tick
///   replaces one that main has not taken yet.
///
/// While no subscriber of a display is armed, its link is paused, so no thread wakes, and it runs at
/// the fastest rate an armed subscriber asked for. The link goes with the display's last subscriber;
/// the display's thread stays, asleep in its run loop. Chrome keeps a display's link the same way:
/// `DisplayLinkMac` lives while a consumer holds it and stops its `CADisplayLink` when the last
/// `VSyncCallbackMac` unregisters (`ui/display/mac/display_link_mac.mm`), so the next arm needs no
/// main-thread hop to make a link. A display that never gets a link (no screen) gets no thread.
///
/// Subscribe and cancel on the main thread (the real link comes from `NSScreen`). Arm and disarm
/// from any thread.
///
/// ```swift
/// let hub = VSyncHub()
/// let surface = hub.subscribe(to: display, owner: "terminal 3") { tick in
///     renderer.draw(at: tick.targetNanoseconds) ? .more : .done
/// }
/// surface?.arm() // the content changed
/// ```
@MainActor
public final class VSyncHub {
    /// Makes `display`'s link that calls `target` at every vsync; nil when the display has no screen.
    public typealias LinkFactory = @MainActor (_ display: CGDirectDisplayID, _ target: LinkTarget) -> (any VSyncLink)?
    /// Runs main-actor work on a later pass of the main run loop (``MainRunLoopBlock`` outside tests).
    public typealias MainPost = @Sendable (_ body: @escaping @MainActor @Sendable () -> Void) -> Void

    /// One vsync of a display (Chrome's `BeginFrameArgs`: frame time, deadline, sequence).
    public struct Tick: Sendable, Equatable {
        /// The display that ticked.
        public let display: CGDirectDisplayID
        /// When the frame that is showing now was shown (`CACurrentMediaTime` timebase).
        public let timestamp: CFTimeInterval
        /// When the next frame shows: work for it must be committed before this time.
        public let targetTimestamp: CFTimeInterval
        /// Counts this display's vsyncs, from 1.
        public let sequence: UInt64

        /// A tick from its values (the hub makes them; tests build them).
        public init(display: CGDirectDisplayID, timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, sequence: UInt64) {
            self.display = display
            self.timestamp = timestamp
            self.targetTimestamp = targetTimestamp
            self.sequence = sequence
        }

        /// The display's frame interval at this vsync, in seconds.
        public var refreshInterval: Double { targetTimestamp - timestamp }

        /// ``targetTimestamp`` in nanoseconds of the same timebase.
        public var targetNanoseconds: UInt64 {
            targetTimestamp > 0 ? UInt64(targetTimestamp * 1_000_000_000) : 0
        }
    }

    /// What a subscriber wants after a tick.
    public enum Demand: Sendable {
        /// Stay armed: tick at the next vsync too.
        case more
        /// Nothing was drawn: disarm until the next ``Subscription/arm()``.
        case done
    }

    private let makeLink: LinkFactory
    let postToMain: MainPost
    let mediaTime: @Sendable () -> CFTimeInterval
    /// Displays that got a link once; each keeps its thread.
    private var displays: [CGDirectDisplayID: Display] = [:]
    /// Subscribers per display.
    private var subscriberCounts: [CGDirectDisplayID: Int] = [:]
    /// Displays whose link exists now (made with a subscriber, dropped with the last one or by a
    /// rebuild that found no screen).
    private var linked: Set<CGDirectDisplayID> = []
    /// Live subscription ids and their displays.
    private var live: [UInt64: CGDirectDisplayID] = [:]
    private var nextID: UInt64 = 0
    /// The main fan-out's hop: from the hub thread's post to main taking the tick.
    public let mainHop: HopMeter
    /// Links made since creation, rebuilds included (debug).
    public private(set) var linksMade: UInt64 = 0
    /// Hub threads started since creation: one per display that got a link (debug).
    public private(set) var threadsStarted: UInt64 = 0

    /// - Parameters:
    ///   - makeLink: Makes a display's link; nil for the real `NSScreen` link.
    ///   - postToMain: Queues the main fan-out's delivery; nil for ``MainRunLoopBlock`` (common
    ///     modes, so ticks also arrive while a menu or a drag tracks events).
    ///   - mediaTime: Stands in for `CACurrentMediaTime`, the timebase of the hop meter.
    public init(makeLink: LinkFactory? = nil, postToMain: MainPost? = nil,
                mediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.makeLink = makeLink ?? { display, target in VSyncHub.screenLink(display: display, target: target) }
        self.postToMain = postToMain ?? { body in MainRunLoopBlock.perform(body) }
        self.mediaTime = mediaTime
        mainHop = HopMeter()
    }

    // MARK: Subscribers

    /// Adds a subscriber to `display`, making the display's link when it has none. The display's
    /// thread starts with its first link, so a display with no screen costs only the factory call.
    ///
    /// - Parameters:
    ///   - display: The display whose vsync drives the subscriber.
    ///   - owner: Names the subscriber in debug output.
    ///   - armed: Whether it ticks at the next vsync (otherwise after its first ``Subscription/arm()``).
    ///   - onVSync: Runs on the display's hub thread, never on main, at each vsync while armed.
    ///     It must not block: every subscriber of the display waits for it.
    /// - Returns: The subscription (cancel it on main when done), or nil when the display has no
    ///   screen, so no link can exist.
    public func subscribe(to display: CGDirectDisplayID, owner: String, armed: Bool = false,
                          onVSync: @escaping @Sendable (Tick) -> Demand) -> Subscription? {
        // A display seen for the first time has no thread until its link exists.
        let state = displays[display] ?? Display(id: display, threadName: "cmux-next vsync \(display)")
        if !linked.contains(display) {
            guard let link = makeLink(display, LinkTarget(display: state)) else { return nil }
            install(link, on: state)
        }
        subscriberCounts[display, default: 0] += 1
        nextID += 1
        live[nextID] = display
        state.add(Entry(id: nextID, owner: owner, callback: onVSync, armed: armed))
        return Subscription(hub: self, display: state, id: nextID)
    }

    func cancel(_ subscription: Subscription) {
        guard let display = live.removeValue(forKey: subscription.id) else { return }
        let left = subscriberCounts[display, default: 1] - 1
        subscriberCounts[display] = left
        if left == 0 { linked.remove(display) }
        subscription.display.remove(subscription.id, lastSubscriber: left == 0)
    }

    /// Replaces `display`'s link with a new one from the factory: a frame clock's stall rebuild (a
    /// link that stopped after display sleep or a reconfiguration). Every subscriber of the display
    /// keeps its subscription and ticks on the new link. When the factory finds no screen, the stuck
    /// link is dropped, and the next ``subscribe(to:owner:armed:onVSync:)`` tries again.
    ///
    /// - Returns: Whether a new link was made.
    @discardableResult
    public func rebuildLink(display: CGDirectDisplayID) -> Bool {
        guard let state = displays[display], subscriberCounts[display, default: 0] > 0 else { return false }
        guard let link = makeLink(display, LinkTarget(display: state)) else {
            linked.remove(display)
            state.dropLinkLater()
            return false
        }
        install(link, on: state)
        return true
    }

    /// Hands `link` to `state`'s thread (it replaces the old one there) and starts the thread with
    /// the display's first link.
    private func install(_ link: any VSyncLink, on state: Display) {
        displays[state.id] = state
        linked.insert(state.id)
        linksMade += 1
        if state.install(link) { threadsStarted += 1 }
    }

    // MARK: Debug

    /// Displays whose link runs now: a link exists and a subscriber is armed (0 at idle). A display
    /// whose subscribers are all disarmed keeps a paused link, which wakes no thread (``pausedLinks``).
    public var liveLinks: Int { linked.filter { (displays[$0]?.armedCount ?? 0) > 0 }.count }

    /// Displays whose link exists but is paused: subscribers, none armed.
    public var pausedLinks: Int { linked.count - liveLinks }

    /// Hub threads running now (one per display that got a link; ``stopThreads()`` ends them).
    public var runningThreads: Int { displays.values.filter(\.hasThread).count }

    /// Subscribers of `display` that tick at its next vsync.
    public func armedSubscribers(on display: CGDirectDisplayID) -> Int {
        displays[display]?.armedCount ?? 0
    }

    /// Vsyncs `display`'s link delivered since creation.
    public func vsyncs(on display: CGDirectDisplayID) -> UInt64 {
        displays[display]?.vsyncCount ?? 0
    }

    /// Drops every link and ends every hub thread (tests: a running app keeps its threads).
    public func stopThreads() {
        for state in displays.values { state.stop() }
        displays.removeAll()
        subscriberCounts.removeAll()
        linked.removeAll()
        live.removeAll()
    }

    /// Runs `work` on `display`'s hub thread after everything posted there before it, and returns once
    /// it ran (tests: a fake link's vsync runs where a real link's would).
    func onHubThread(_ display: CGDirectDisplayID, _ work: @escaping @Sendable () -> Void) async {
        guard let state = displays[display] else { return }
        // A hub thread that ended with the post queued drops it (abandoned): the wait just ends.
        try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in
            state.post {
                work()
                done.resume(returning: ())
            }
        }
    }

    // MARK: Real link

    /// `display`'s `NSScreen` link; the hub thread adds it to its own run loop.
    private static func screenLink(display: CGDirectDisplayID, target: LinkTarget) -> (any VSyncLink)? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == display }) else {
            return nil
        }
        // The one display link of this display (scripts/cmux-next/check-concurrency.sh allows it only here).
        let link = screen.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        // Springs step every display frame until an armed subscriber asks for less.
        link.preferredFrameRateRange = FrameRate.motion.range
        return ScreenVSyncLink(link)
    }
}

extension VSyncHub {
    /// One subscriber of a display's vsync. Arm and disarm from any thread; cancel on main.
    public final class Subscription: Sendable {
        private let hub: VSyncHub
        let display: Display
        let id: UInt64

        init(hub: VSyncHub, display: Display, id: UInt64) {
            self.hub = hub
            self.display = display
            self.id = id
        }

        /// Ticks at the next vsync and every vsync after it until the callback returns
        /// ``Demand/done`` or ``disarm()``. An arm during a tick keeps the subscriber armed even when
        /// that tick's callback returns ``Demand/done``.
        public func arm() { display.arm(id) }

        /// Stops ticking; the link pauses when no subscriber of the display is armed.
        public func disarm() { display.disarm(id) }

        /// Asks for `range` while armed (the display's full rate until then). The link runs at the
        /// fastest rate any armed subscriber of the display asked for.
        public func requestFrameRate(_ range: CAFrameRateRange) { display.request(id, rate: LinkRate(range)) }

        /// Replaces the display's link (``VSyncHub/rebuildLink(display:)``); false when no new link
        /// could be made.
        @MainActor public func relink() -> Bool { hub.rebuildLink(display: display.id) }

        /// Leaves the display; its link goes with the last subscriber. No effect after the first call.
        @MainActor public func cancel() { hub.cancel(self) }
    }

    /// The object a display's link calls at every vsync, on the display's hub thread. The real
    /// factory binds it with `#selector(LinkTarget.tick(_:))`; a fake link calls
    /// ``vsync(timestamp:targetTimestamp:)``.
    public final class LinkTarget: NSObject, Sendable {
        private let display: Display

        init(display: Display) {
            self.display = display
            super.init()
        }

        /// The real link's tick.
        @objc public func tick(_ link: CADisplayLink) {
            display.vsync(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }

        /// One vsync. Call it only on the thread the link was attached on (the display's hub thread).
        public func vsync(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
            display.vsync(timestamp: timestamp, targetTimestamp: targetTimestamp)
        }
    }
}
