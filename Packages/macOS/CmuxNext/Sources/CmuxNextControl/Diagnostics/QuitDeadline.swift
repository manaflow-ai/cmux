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
/// Armed when a keep quit is decided (`keepQuitLimit`), or when an End quit's
/// engines start to stop (`engineStopLimit`), a dedicated thread ends the
/// process if it is still running `limit` later. By then every save step
/// ran or passed its limit (windows, sidebar, browser records, agent page
/// images), and the run marker says a quit had begun
/// (`AppRunMarker.markQuitting`), so the next launch restores as after a
/// normal quit. It never waits on the main thread, and `_exit` runs no
/// atexit handler or C++ destructor that could wait on a blocked thread.
public nonisolated final class QuitDeadline: Sendable {
    /// A quit that keeps the sessions (every quit but End Sessions and End
    /// Everything) ends this long after it was decided, whatever any step
    /// does (slow quit, 2026-10-20). The save steps have their own limits
    /// (`QuitSaveSteps.worstCase`, 2.6 s if every one of them hangs, a few
    /// hundred ms in practice), so with the quit mark, the "Don't ask again"
    /// write and the reply margin they end inside this limit; then the
    /// engines' close wait (`engineCloseWait`) and CefShutdown, then the wait
    /// for steps past their limit (`QuitStepLimiter.finishOverruns`), all
    /// of which the deadline cuts.
    public static let keepQuitLimit: Duration = .seconds(4)
    /// An End quit ends this long after its sessions ended and the engines
    /// began to stop: the close wait, then CefShutdown. Chromium's own 10 s
    /// shutdown watchdog is far too late for a quit the user waits on.
    public static let engineStopLimit: Duration = .seconds(3)
    /// How long the quit waits for Chromium to close its browsers before
    /// CefShutdown (`CEFEngine.shutdown`); a close that takes longer skips
    /// CefShutdown, and with it Chromium's last cookie and storage flush.
    /// Chromium gives a page's beforeunload about 1 s, so a page that spins
    /// in it still closes within this wait.
    public static let engineCloseWait: Duration = .seconds(2)
    /// How long a quit waits for its `quitting` run mark to reach disk
    /// (`AppRunMarker.markQuitting`), before every save step.
    public static let quitMarkLimit: Duration = .milliseconds(500)
    /// What a quit leaves before its deadline for AppKit's reply and the
    /// normal exit (the clean-exit mark) once its steps are done.
    public static let replyMargin: Duration = .milliseconds(200)

    private let armed = Atomic<Bool>(false)
    private let firesAt = Mutex<ContinuousClock.Instant?>(nil)
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

    /// The time left before the deadline ends the process, less `margin`;
    /// zero once that has passed, nil while it is not armed.
    public func timeLeft(margin: Duration = .zero) -> Duration? {
        firesAt.withLock { $0 }.map { max(.zero, $0 - .now - margin) }
    }

    /// Starts the deadline once; a later call keeps the first.
    public func arm(after limit: Duration) {
        guard armed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        firesAt.withLock { $0 = .now + limit }
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
