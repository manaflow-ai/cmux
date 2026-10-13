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
nonisolated final class QuitDeadline: Sendable {
    /// The engines' close wait (3 s, `CEFEngine.shutdown`) and Chromium's
    /// own 10 s shutdown watchdog, with room for a loaded machine.
    static let engineStopLimit: Duration = .seconds(15)

    private let armed = Atomic<Bool>(false)
    private let end: @Sendable () -> Void

    /// `end` runs on the deadline thread; the app's ends the process.
    init(end: @escaping @Sendable () -> Void = { _exit(0) }) {
        self.end = end
    }

    /// Starts the deadline once; a later call keeps the first.
    func arm(after limit: Duration) {
        guard armed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        let end = end
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let thread = Thread {
            // concurrency-allow: the dedicated quit-deadline thread waits out the limit; never the main thread.
            let never = DispatchSemaphore(value: 0)
            // concurrency-allow: same dedicated thread; nothing signals it, so this is the deadline.
            _ = never.wait(timeout: .now() + seconds)
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .fault("quit still running \(seconds, privacy: .public) s after the engines began to stop; ending the process")
            end()
        }
        thread.name = "cmux-next quit deadline"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
