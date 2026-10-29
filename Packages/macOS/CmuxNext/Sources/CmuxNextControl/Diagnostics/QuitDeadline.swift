import CmuxNextCompat
import Darwin
import Foundation
import os

/// The hard end of a decided quit (cx-ccjnn). The quit's last step stops the
/// browser engines on the main thread, and CefShutdown can block it for
/// good: on a capture mini its Chromium teardown waited forever on a
/// keychain read (the main thread in a Chromium mach_msg; Chromium's own
/// 10 s shutdown watchdog never fired). The app never exited, and every
/// later main-actor request (`action.run`) timed out as `not_run`.
///
/// Armed when the engines start to stop, a dedicated thread ends the process
/// if it is still running `limit` later. By then everything a relaunch
/// needs is saved (windows, sidebar, browser records, agent page images),
/// and the run marker says a quit had begun (`AppRunMarker.markQuitting`), so
/// the next launch restores as after a normal quit. It never waits on the
/// main thread, and `_exit` runs no atexit handler or C++ destructor that
/// could wait on the blocked Chromium thread.
public nonisolated final class QuitDeadline: Sendable {
    /// The engines' close wait (3 s, `CEFEngine.shutdown`) and Chromium's
    /// own 10 s shutdown watchdog, with room for a loaded machine.
    public static let engineStopLimit: Duration = .seconds(15)

    private let armed = Atomic<Bool>(false)
    private let end: @Sendable () -> Void
    private let reason: String

    /// - Parameters:
    ///   - reason: What the limit counts from, for the fault log line ("quit still running N s after
    ///     <reason>"); the default is the engine stop's.
    ///   - end: Runs on the deadline thread; the default ends the process.
    public init(reason: String = "the engines began to stop", end: (@Sendable () -> Void)? = nil) {
        self.reason = reason
        self.end = end ?? { _exit(0) }
    }

    /// Starts the deadline once; a later call keeps the first.
    public func arm(after limit: Duration) {
        guard armed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        let end = end
        let reason = reason
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let thread = Thread {
            // concurrency-allow: the dedicated quit-deadline thread waits out the limit; never the main thread.
            let never = DispatchSemaphore(value: 0)
            // concurrency-allow: same dedicated thread; nothing signals it, so this is the deadline.
            _ = never.wait(timeout: .now() + seconds)
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .fault("quit still running \(seconds, privacy: .public) s after \(reason, privacy: .public); ending the process")
            end()
        }
        thread.name = "cmux-next quit deadline"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension QuitDeadline {
    /// A debug seam for the quit's last step: blocks the main thread for
    /// good, as CefShutdown did on a capture mini, so a journey can prove
    /// that a quit still ends. Armed only by
    /// `debug.quit {wedge_engine_stop: true}`; debug builds only.
    @MainActor
    public func wedgeMainThread(_ watchdog: MainThreadWatchdog?) {
        // As in a release build: the hang is reported, never asserted.
        watchdog?.endHangAssertions()
        // concurrency-allow: debug seam that blocks the main thread on purpose, as the wedged CefShutdown did
        let never = DispatchSemaphore(value: 0)
        // concurrency-allow: debug seam; nothing signals it, the process must end around it
        never.wait()
    }
}
#endif
