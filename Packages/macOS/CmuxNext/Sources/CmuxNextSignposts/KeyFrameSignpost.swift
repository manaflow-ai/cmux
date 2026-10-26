import Carbon.HIToolbox
public import Foundation

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the end
/// of the Core Animation commit that ends that turn.
///
/// Message: `target=<view|terminal> age_ms=<age>`, the key's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval. For a text view (the Home composer, the omnibar, a field) the
/// commit carries the typed character; for a terminal it carries the key's own work only, and the echo comes back
/// from the shell in a later frame, so `target=terminal` rows are the main thread's share of the key.
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

    private let signposter: Signposter
    /// The most keys one run-loop turn holds open; a key past it records no interval.
    private let capacity: Int
    /// The keys begun since the observer last fired, reserved to ``capacity`` once.
    private var pending: [KeyFrameInterval] = []
    /// Whether secure event input is on now, read once per key-down (the system's `IsSecureEventInputEnabled`).
    private let secureEventInput: () -> Bool

    /// The app's key-frame signposts: ``Signposter/key``, ended by an observer on the main run loop, gated by the
    /// system's secure event input.
    public convenience init() {
        self.init(signposter: .key, secureEventInput: { IsSecureEventInputEnabled() })
        installOnMainRunLoop()
    }

    /// Key-frame signposts with no observer: the caller fires ``runLoopReached(_:)`` (tests).
    ///
    /// - Parameters:
    ///   - signposter: The key category's signposter.
    ///   - capacity: The most keys one turn holds open (several keys can dispatch in one turn when events queue).
    ///   - secureEventInput: Whether secure event input is on now (tests pass their own).
    init(signposter: Signposter, capacity: Int = 64, secureEventInput: @escaping () -> Bool = { false }) {
        self.signposter = signposter
        self.capacity = capacity
        self.secureEventInput = secureEventInput
        pending.reserveCapacity(capacity)
    }

    /// How many keys are open (tests).
    var openCount: Int { pending.count }

    /// Begins the interval for a key-down dispatched now; it ends after this main run-loop turn's commit. It first
    /// sets or clears the ``TraceRuntime/KeyTimingHold/secureEventInput`` hold from the system's secure event input,
    /// so while that is on no interval begins and the key flows and the ring take no key timing either.
    ///
    /// - Parameters:
    ///   - target: What has the keyboard.
    ///   - eventTimestamp: The key event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    ///   - now: Seconds since boot now (`ProcessInfo.systemUptime`, the event timestamp's clock).
    public func begin(target: Target, eventTimestamp: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        signposter.trace.setKeyTimingSuppressed(secureEventInput(), by: .secureEventInput)
        guard signposter.isEnabled, pending.count < capacity else { return }
        pending.append(signposter.begin(.keyToFrame, target: target,
                                        ageMicros: Self.ageMicros(eventTimestamp: eventTimestamp, now: now)))
    }

    /// Ends every open key: committed before waiting or on exit, missed after a wake (the observer's callout).
    func runLoopReached(_ activity: CFRunLoopActivity) {
        guard !pending.isEmpty else { return }
        let outcome: CommitBoundary.Outcome = activity == .afterWaiting ? .missed : .committed
        for interval in pending {
            signposter.end(.keyToFrame, interval, outcome)
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
