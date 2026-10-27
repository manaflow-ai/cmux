import CmuxVNCWebRTC
import Foundation

/// A one-shot deadline on the main actor: the stats line's next sample (``ScreenSession/useStatsDeadline(_:)``).
/// It never repeats: ``schedule(after:_:)`` replaces a pending deadline and ``cancel()`` drops it. CmuxNext backs it
/// with a visible-class `MainDeadline` named `MacScreen.stats`, an entry of the main thread's one wake-up queue
/// (Chromium posts a delayed task to the UI sequence, whose `WakeUpQueue` arms the pump's one timer,
/// base/message_loop/message_pump_apple.mm). A host that makes none gets ``RunLoopScreenDeadline``.
@MainActor
public protocol ScreenDeadline: AnyObject {
    /// Runs `action` once, `seconds` from now, in place of a pending deadline.
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
    /// A deadline is scheduled and has not run.
    var isPending: Bool { get }
}

/// The standalone deadline: a one-shot `Timer` on the main run loop with a tenth of its delay as tolerance (at
/// least Chromium's `kDefaultLeeway`, 8 ms, base/task/task_features.h), so the system can share its wake.
@MainActor
public final class RunLoopScreenDeadline: ScreenDeadline {
    private var timer: Timer?

    public init() {}

    public func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer?.invalidate()
        let delay = max(0, seconds)
        // wakeup-allow: deadline one shot (repeats: false) with a tolerance; replaced or cancelled, never re-armed by itself
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            // main-proof: the timer is added to the main run loop only (below), so it fires on the main thread.
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = Self.tolerance(delay)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }

    public var isPending: Bool { timer?.isValid == true }

    /// A tenth of `delay`, at least 8 ms; none for a deadline that is already due.
    nonisolated static func tolerance(_ delay: Double) -> Double {
        delay > 0 ? max(0.008, delay / 10) : 0
    }
}

/// Where the stats line's numbers come from: a screen stream's WebRTC receiver (``ScreenStreamViewer``).
public protocol ScreenVideoStatsSource: AnyObject, Sendable {
    /// WebRTC's numbers now; `bytesReceived` counts from the connect, not from the last read.
    func videoStats() async -> ScreenStreamViewer.VideoStats
}

extension ScreenStreamViewer: ScreenVideoStatsSource {}
