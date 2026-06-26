import Darwin
import Foundation

/// Hard deadline on AppKit's application-termination sequence.
///
/// `-[NSApplication terminate:]` synchronously posts `NSApplicationWillTerminate`
/// and drives a gauntlet of observers — several of them Apple's own and outside
/// our control. One is `CFPasteboardResolveAllPromisedData`, which flushes
/// promised (lazy) pasteboard data with a blocking mach round-trip to the
/// pasteboard server. When a clipboard-history manager (Paste, Raycast, Maccy,
/// Pastebot, …) is mid-read of cmux's promised clipboard data, that round-trip
/// can wedge for ~30s on the main thread until the OS force-kills the app
/// (https://github.com/manaflow-ai/cmux/issues/6758). The same structural gap —
/// quit having no global "return within N seconds no matter what" guard —
/// produced #6415 (`PostHogAnalytics.flush()`) and #6381 (`ghostty` lock).
///
/// This watchdog closes that gap. It runs on a dedicated background thread with
/// no run-loop, GCD-queue, or main-actor dependency, so it fires even while the
/// main thread is parked in `mach_msg`. Arm it the instant the app commits to
/// quitting; if the process has not exited within `deadline`, it force-exits,
/// turning a multi-second hang into a bounded quit. cmux's critical
/// session/state save runs synchronously *before* the watchdog is armed, so the
/// bytes that matter are already on disk if the deadline ever fires.
final class TerminationWatchdog: Sendable {
    /// The process-wide watchdog. `onFire` logs a breadcrumb and force-exits
    /// cleanly — the user asked to quit, so an immediate exit is the desired
    /// outcome once the deadline proves the graceful path is wedged.
    static let shared = TerminationWatchdog {
        StartupBreadcrumbLog.append("appDelegate.terminate.watchdogFired")
        _exit(EXIT_SUCCESS)
    }

    /// Budget for the committed-quit sequence (remote-session kill defer plus
    /// AppKit's will-terminate gauntlet). Normal teardown finishes in well under
    /// a second; this leaves generous headroom while still beating the OS's
    /// ~30s hang watchdog by a wide margin.
    static let defaultDeadline: TimeInterval = 8

    private let lock = NSLock()
    // SAFETY: guarded by `lock`; latched from the arming caller (main thread)
    // and read by the watchdog/test threads.
    nonisolated(unsafe) private var isArmed = false
    private let onFire: @Sendable () -> Void

    /// - Parameter onFire: invoked at most once, on the watchdog thread, when
    ///   the deadline elapses. Defaults to a clean force-exit; tests inject an
    ///   observer in its place.
    init(onFire: @escaping @Sendable () -> Void = { _exit(EXIT_SUCCESS) }) {
        self.onFire = onFire
    }

    /// Arms the one-shot deadline. Idempotent: repeated calls — multiple quit
    /// attempts, or several commit sites arming for one request — never stack
    /// threads, so `onFire` runs at most once.
    func arm(deadline: TimeInterval = TerminationWatchdog.defaultDeadline) {
        lock.lock()
        if isArmed {
            lock.unlock()
            return
        }
        isArmed = true
        lock.unlock()

        // Regression baseline (red commit): the watchdog thread that invokes
        // `onFire` after `deadline` is intentionally not started yet, so
        // TerminationWatchdogTests fails. The fix commit starts it.
        _ = deadline
    }
}
