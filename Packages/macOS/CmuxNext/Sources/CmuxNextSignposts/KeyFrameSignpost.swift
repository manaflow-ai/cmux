import CmuxNextCompat
import CmuxNextMetrics
import CoreFoundation
public import Foundation

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the end
/// of the Core Animation commit that ends that turn.
///
/// Message: `target=<view|terminal> age_ms=<age>`, the key's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval. For a text view (the Home composer, the omnibar, a field) the
/// commit carries the typed character; for a terminal it carries the key's own work only, and the echo comes back
/// from the shell in a later frame, so `target=terminal` rows are the main thread's share of the key.
///
/// Each committed key is also a sample of the field histogram `key.frame.<target>` (``HistogramID/keyFrame(_:)``,
/// task 054): from the key-down (the event's timestamp, so its wait in the queue counts) to the end of that commit,
/// as Chrome's `EventLatency.KeyPressed.TotalLatency` runs from the OS event's timestamp to its frame
/// (cc/metrics/event_metrics.h). The histogram records whether or not anything takes the signposts. A key ended as
/// missed records nothing: the run loop slept before its commit, so its time would hold the idle wait.
///
/// It runs on every key for every user, so a key makes no heap allocation: the typed begin and end
/// (``Signposter/begin(_:target:ageMicros:)``) emit through os_signpost's C macros, the open intervals are plain
/// values in a buffer reserved once, and one repeating main run-loop observer, installed by the convenience
/// ``init()``, ends them. That observer runs at ``CommitBoundary/order``, one after Core Animation's commit, and
/// fires as a ``CommitBoundary`` does: before waiting and on exit it ends the open keys as committed; when the
/// run loop wakes first it ends them as missed. Chromium's message pump keeps its run-loop observers the same
/// way, made once for the pump's life (base/message_loop/message_pump_apple.mm, `PreWaitObserver`). A key begun
/// in a before-waiting callout ahead of the commit ends at that commit, where a one-shot ``CommitBoundary``,
/// installed too late for that pass, would report it missed.
///
/// Each key-down first samples the system's secure event input into the trace runtime's keystroke-timing gate
/// (``TraceRuntime/KeyTimingHold/secureEventInput``, task 128): Chromium turns it on for a focused password field
/// (ui/base/cocoa/secure_password_input.mm `ScopedPasswordInputEnabler`) and Ghostty for a terminal's password
/// prompt, and while it is on no key timing is recorded, here, in the key flows or in the ring.
///
/// The app holds one for its life (CmuxNextInput's `InputFrameSignposts`, which begins a key's interval when its input
/// latency slot opens); when it is released, its observer removes itself at its next callout.
///
/// ```swift
/// keyFrames.begin(target: .view, eventTimestamp: event.timestamp)
/// ```
@MainActor
public final class KeyFrameSignpost {
    /// What has the keyboard when the key is dispatched.
    public nonisolated enum Target: String, Sendable {
        /// A text view or any view that is not a terminal: the commit shows the typed character.
        case view
        /// A terminal: the commit shows the key's own work; the echo is a later frame.
        case terminal
    }

    /// One key begun since the observer last fired.
    struct OpenKey {
        /// Its signpost interval; nil while nothing took key signposts at its begin (``Signposter/isEnabled``).
        let interval: KeyFrameInterval?
        let target: Target
        /// `CLOCK_UPTIME_RAW` nanoseconds of the key-down: its dispatch begin less its age (the begin itself when the
        /// event had no timestamp).
        let keyDownNanos: UInt64
    }

    private let signposter: Signposter
    /// Where each committed key's `key.frame.<target>` sample goes.
    private let metrics: Metrics
    /// The most keys one run-loop turn holds open; a key past it records no interval.
    private let capacity: Int
    /// The keys begun since the observer last fired, reserved to ``capacity`` once.
    private var pending: [OpenKey] = []
    /// Whether secure event input is on now, read once per key-down (the system's `IsSecureEventInputEnabled`).
    private let secureEventInput: () -> Bool
    /// Gets each committed key's `key.frame` time in microseconds, after its sample (the app's opt-in hang reports take
    /// the black box at a slow one); nil: nothing gets it.
    public var committedKey: ((_ micros: UInt64) -> Void)?

    /// The app's key-frame signposts: ``Signposter/key``, ended by an observer on the main run loop, gated by the
    /// system's secure event input.
    public convenience init() {
        self.init(signposter: .key, secureEventInput: { KeyFrameSignpost.systemSecureEventInput() })
        installOnMainRunLoop()
    }

    /// Key-frame signposts with no observer: the caller fires ``runLoopReached(_:)`` (tests).
    ///
    /// - Parameters:
    ///   - signposter: The key category's signposter.
    ///   - metrics: Where the `key.frame` samples go; nil: the store of the signposter's trace runtime.
    ///   - capacity: The most keys one turn holds open (several keys can dispatch in one turn when events queue).
    ///   - secureEventInput: Whether secure event input is on now (tests pass their own).
    init(signposter: Signposter, metrics: Metrics? = nil, capacity: Int = 64,
         secureEventInput: @escaping () -> Bool = { false }) {
        self.signposter = signposter
        self.metrics = metrics ?? Metrics(runtime: signposter.trace)
        self.capacity = capacity
        self.secureEventInput = secureEventInput
        pending.reserveCapacity(capacity)
    }

    /// How many keys are open (tests).
    var openCount: Int { pending.count }

    /// Begins the interval for a key-down dispatched now; it ends after this main run-loop turn's commit. It first
    /// sets or clears the ``TraceRuntime/KeyTimingHold/secureEventInput`` hold from the system's secure event input,
    /// so while that is on (or another hold closes the keystroke-timing gate) no key opens: no interval, no
    /// `key.frame` sample, and the key flows and the ring take no key timing either.
    ///
    /// - Parameters:
    ///   - target: What has the keyboard.
    ///   - eventTimestamp: The key event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    ///   - now: Seconds since boot now (`ProcessInfo.systemUptime`, the event timestamp's clock).
    public func begin(target: Target, eventTimestamp: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        signposter.trace.setKeyTimingSuppressed(secureEventInput(), by: .secureEventInput)
        guard !signposter.trace.isKeyTimingSuppressed, pending.count < capacity else { return }
        let ageMicros = Self.ageMicros(eventTimestamp: eventTimestamp, now: now)
        let interval = signposter.isEnabled ? signposter.begin(.keyToFrame, target: target, ageMicros: ageMicros) : nil
        let beginNanos = interval?.beginUptimeNanos ?? signposter.clock.nowNanos()
        let ageNanos = UInt64(max(ageMicros, 0)) &* 1_000
        pending.append(OpenKey(interval: interval, target: target, keyDownNanos: beginNanos - min(ageNanos, beginNanos)))
    }

    /// Ends every open key: committed before waiting or on exit, missed after a wake (the observer's callout). A
    /// committed key records its `key.frame.<target>` sample, key-down to now.
    func runLoopReached(_ activity: CFRunLoopActivity) {
        guard !pending.isEmpty else { return }
        let outcome: CommitBoundary.Outcome = activity == .afterWaiting ? .missed : .committed
        let endNanos = signposter.clock.nowNanos()
        for key in pending {
            if let interval = key.interval { signposter.end(.keyToFrame, interval, outcome) }
            guard outcome == .committed else { continue }
            let micros = endNanos > key.keyDownNanos ? (endNanos - key.keyDownNanos) / 1_000 : 0
            metrics.record(.keyFrame(key.target.histogramTarget), Int64(truncatingIfNeeded: micros))
            committedKey?(micros)
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// Adds the repeating observer to the main run loop's common modes: once, from the convenience init (tests call
    /// it on their own instance).
    func installOnMainRunLoop() {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CommitBoundary.order) {
            [weak self] firing, activity in
            guard let self else { return CFRunLoopObserverInvalidate(firing) }
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { self.runLoopReached(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    /// The key's age in microseconds (rounded) when its dispatch began (never negative), -1 when it has no timestamp.
    nonisolated static func ageMicros(eventTimestamp: TimeInterval, now: TimeInterval) -> Int64 {
        eventTimestamp > 0 ? Int64((max(0, now - eventTimestamp) * 1_000_000).rounded()) : -1
    }
}

extension KeyFrameSignpost.Target {
    /// The `key.frame` histogram of this target (``HistogramID/keyFrame(_:)``).
    var histogramTarget: HistogramID.KeyTarget {
        switch self {
        case .view: .view
        case .terminal: .terminal
        }
    }
}
