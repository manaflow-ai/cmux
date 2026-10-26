public import AppKit
public import QuartzCore
import CmuxNextCompat

/// What the hub needs from a display link (a fake in tests). The hub makes it on the main thread
/// through its factory and hands it to the display's hub thread; every call after that runs there.
public protocol VSyncLink: AnyObject, Sendable {
    /// Adds the link to the calling thread's run loop. The hub calls it once, on the display's hub
    /// thread, so the link's ticks run there.
    func attachToCurrentRunLoop()
    var isPaused: Bool { get set }
    func invalidate()
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
/// While no subscriber of a display is armed, its link is paused, so no thread wakes. The link goes
/// with the display's last subscriber; the display's thread stays, asleep in its run loop.
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
        public let display: CGDirectDisplayID
        /// When the frame that is showing now was shown (`CACurrentMediaTime` timebase).
        public let timestamp: CFTimeInterval
        /// When the next frame shows: work for it must be committed before this time.
        public let targetTimestamp: CFTimeInterval
        /// Counts this display's vsyncs, from 1.
        public let sequence: UInt64

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
    private var displays: [CGDirectDisplayID: Display] = [:]
    /// Subscribers per display; a display's link exists while its count is above 0.
    private var subscriberCounts: [CGDirectDisplayID: Int] = [:]
    /// Live subscription ids and their displays.
    private var live: [UInt64: CGDirectDisplayID] = [:]
    private var nextID: UInt64 = 0
    /// The main fan-out's hop: from the hub thread's post to main taking the tick.
    public let mainHop: HopMeter
    /// Links made since creation (debug).
    public private(set) var linksMade: UInt64 = 0

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

    /// Adds a subscriber to `display`, making the display's link when it is the first.
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
        let isNew = displays[display] == nil
        let state = displays[display] ?? Display(id: display, threadName: "cmux-next vsync \(display)")
        if subscriberCounts[display, default: 0] == 0 {
            guard let link = makeLink(display, LinkTarget(display: state)) else {
                if isNew { state.stop() }
                return nil
            }
            displays[display] = state
            linksMade += 1
            state.install(link)
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
        subscription.display.remove(subscription.id, lastSubscriber: left == 0)
    }

    // MARK: Debug

    /// Displays whose link exists now (one per display with a subscriber; 0 when none).
    public var liveLinks: Int { subscriberCounts.values.filter { $0 > 0 }.count }

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
        live.removeAll()
    }

    /// Runs `work` on `display`'s hub thread after everything posted there before it, and returns once
    /// it ran (tests: a fake link's vsync runs where a real link's would).
    func onHubThread(_ display: CGDirectDisplayID, _ work: @escaping @Sendable () -> Void) async {
        guard let state = displays[display] else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            state.post {
                work()
                done.resume()
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
        link.preferredFrameRateRange = motionRange
        return ScreenVSyncLink(link)
    }

    /// Springs step every display frame: 120 Hz on ProMotion (never below 80), the display's rate elsewhere.
    private static let motionRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
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
