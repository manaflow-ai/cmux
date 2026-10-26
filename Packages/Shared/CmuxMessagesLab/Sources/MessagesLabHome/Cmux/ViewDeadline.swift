// cmux: the seam where the vendored AppKit views run one-shot deadlines on the main actor. Not a vendored file.
import Foundation

/// A vendored view's one-shot deadline on the main actor (NativeScroll's fade-in, widen and hide). It
/// never repeats: ``schedule(after:_:)`` replaces a pending deadline and ``cancel()`` drops it. The host
/// makes each one through ``ChatWakeScheduler/makeDeadline(owner:exact:)``. CmuxNext backs it with a
/// `MainDeadline` in the visible class, an entry of the main thread's one wake-up queue (Chromium posts a
/// delayed task to the UI sequence, whose `WakeUpQueue` arms the pump's one timer,
/// base/message_loop/message_pump_apple.mm). A host that makes none gets ``RunLoopDeadline``.
@MainActor
public protocol ViewDeadline: AnyObject {
    /// Runs `action` once, `seconds` from now, in place of a pending deadline.
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
    /// A deadline is scheduled and has not run.
    var isPending: Bool { get }
}

/// The standalone deadline: a one-shot `Timer` on the main run loop (default mode, as
/// `Timer.scheduledTimer` on main) with a tolerance, so the system can share its wake.
@MainActor
public final class RunLoopDeadline: ViewDeadline {
    /// The tolerance of a flexible deadline: Chromium's `kDefaultLeeway`, 8 ms (base/task/task_features.h).
    public static let flexibleTolerance: Double = 0.008
    /// The tolerance each fire gets: 0 when exact.
    public let tolerance: Double
    private var timer: Timer?

    /// - Parameter exact: no tolerance (a deadline measured to the frame); else ``flexibleTolerance``.
    public init(exact: Bool = false) {
        tolerance = exact ? 0 : Self.flexibleTolerance
    }

    public func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer?.invalidate()
        let delay = max(0, seconds)
        // wakeup-allow: deadline one shot (repeats: false) with a tolerance; replaced or cancelled, never re-armed by itself
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            // main-proof: the timer is added to the main run loop only (below), so it fires on the main thread.
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = delay > 0 ? tolerance : 0
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }

    public var isPending: Bool { timer?.isValid == true }

    /// The tolerance the pending timer was given (tests); nil when none is pending.
    var pendingTolerance: Double? { isPending ? timer?.tolerance : nil }
}
