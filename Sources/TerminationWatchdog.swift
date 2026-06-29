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
/// turning a multi-second hang into a bounded quit. The firing path is
/// deliberately unconditional and lock-free — it does no Foundation/filesystem
/// work before exiting, because the termination it guards against may itself be
/// wedged on exactly such a lock. cmux's critical session/state save runs
/// synchronously *before* the watchdog is armed, so the bytes that matter are
/// already on disk if the deadline ever fires.
///
/// Not a singleton: the app's lifecycle owner (`AppDelegate`) holds the
/// instance, alongside its other terminate-control state.
final class TerminationWatchdog: Sendable {
    /// Budget for the committed-quit sequence (remote-session kill defer plus
    /// AppKit's will-terminate gauntlet). Normal teardown finishes in well under
    /// a second; this leaves generous headroom while still beating the OS's
    /// ~30s hang watchdog by a wide margin.
    static let defaultDeadline: TimeInterval = 8

    /// Schedules `fire` to run once after `deadline` seconds. Injectable so tests
    /// advance the deadline by hand instead of sleeping for real.
    typealias DeadlineScheduler =
        @Sendable (_ deadline: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> Void

    /// Production scheduler: a raw `Thread` that sleeps then fires. A raw Thread,
    /// deliberately NOT a GCD queue or `DispatchSourceTimer` — the wedged
    /// termination this guards against can sit on Foundation, GCD, or run-loop
    /// infrastructure, so the firing path must depend on none of it. The thread
    /// parks only during the brief quit window and is reclaimed when the process
    /// exits (the common path, well before the deadline).
    static let threadScheduler: DeadlineScheduler = { deadline, fire in
        let thread = Thread {
            Thread.sleep(forTimeInterval: deadline)
            fire()
        }
        thread.name = "com.cmuxterm.termination-watchdog"
        thread.stackSize = 128 * 1024
        thread.start()
    }

    // Atomic, not an actor: `arm()` is called synchronously from terminate
    // delegate methods and must not depend on Swift concurrency while guarding
    // a wedged termination path. The Int32 is a one-shot 0 -> 1 latch claimed
    // with OSAtomicCompareAndSwap32Barrier, which supports cmux's macOS 14 floor.
    nonisolated(unsafe) private var isArmedFlag: Int32 = 0
    private let onFire: @Sendable () -> Void
    private let scheduleDeadline: DeadlineScheduler

    /// - Parameters:
    ///   - onFire: invoked at most once, on the scheduler's thread, when the
    ///     deadline elapses. It MUST stay lock-free and non-blocking — it runs
    ///     precisely when termination is suspected to be wedged, so any
    ///     Foundation, filesystem, or lock work before exiting could itself stall
    ///     and reintroduce the unbounded hang. The default is a bare `_exit`.
    ///   - scheduleDeadline: how the deadline is scheduled. Defaults to
    ///     ``threadScheduler``; tests inject a synchronous capture so they can
    ///     advance the deadline by hand.
    init(
        onFire: @escaping @Sendable () -> Void = { _exit(EXIT_SUCCESS) },
        scheduleDeadline: @escaping DeadlineScheduler = TerminationWatchdog.threadScheduler
    ) {
        self.onFire = onFire
        self.scheduleDeadline = scheduleDeadline
    }

    /// Arms the one-shot deadline. Idempotent: repeated calls — multiple quit
    /// attempts, or several commit sites arming for one request — schedule the
    /// deadline only once, so `onFire` runs at most once.
    func arm(deadline: TimeInterval = TerminationWatchdog.defaultDeadline) {
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &isArmedFlag) else {
            return
        }

        scheduleDeadline(deadline, onFire)
    }
}
