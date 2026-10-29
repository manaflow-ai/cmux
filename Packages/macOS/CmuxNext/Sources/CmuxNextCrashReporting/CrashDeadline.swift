import Darwin
import Foundation

/// The last guard of the crash path: once a crash has begun (an uncaught
/// Objective-C exception reached the app's handler, or a fatal signal
/// handler ran), the process ends within ``seconds``, whatever else blocks.
///
/// A crash must end the process so that `LaunchRecovery` can relaunch and
/// recover it. On 2026-10-20 two NIGHTLY crashes froze instead (a trap whose
/// Mach exception nothing received, see ``TaskExceptionPorts``) until the
/// user forced them to quit. `TaskExceptionPorts` fixes that cause; this
/// bounds the class: a crash handler that blocks after it let the other
/// threads run again, a recrash in a handler, an exception port whose
/// receiver is gone.
///
/// A dedicated thread, started at launch, waits on a Mach semaphore (no
/// wakeups while the app runs). ``arm()`` signals it from any crash path;
/// it is async-signal-safe (`semaphore_signal`). The thread then waits
/// until ``seconds`` after the arm and, if the process still runs, ends it
/// with SIGABRT at its default action: macOS writes a crash report that
/// holds every thread (the blocked one too), and the next launch forwards
/// it (`SystemCrashForwarder`). With a debugger attached it does nothing.
/// After the arm it allocates nothing (a crash inside malloc can hold the
/// heap lock).
///
/// Limit: Sentry suspends every other thread while it writes its report
/// (`sentrycrashmc_suspendEnvironment`); a Sentry handler that blocks with
/// the threads suspended also stops this thread. ``CrashWatcher``, a child
/// process armed on the same paths, ends that case 15 s after the arm.
enum CrashDeadline {
    /// How long a crash may take before the deadline ends the process. A
    /// normal crash ends in well under a second; Sentry's own concurrent
    /// crash wait is 2 s.
    static let seconds: UInt64 = 10

    /// Starts the deadline thread once. Call at launch, before any handler
    /// that calls ``arm()`` is installed.
    static func install() {
        guard deadlineSemaphore == 0 else { return }
        var semaphore = semaphore_t(0)
        guard semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS else { return }
        deadlineSemaphore = semaphore
        let parked = semaphore
        let thread = Thread { CrashDeadline.watch(parked) }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// A crash has begun: the process ends within ``seconds``.
    /// Async-signal-safe; does nothing before ``install()``.
    static func arm() {
        let semaphore = deadlineSemaphore
        if semaphore != 0 { _ = semaphore_signal(semaphore) }
    }

    /// Suspends the deadline thread, as Sentry's report writer does, for the
    /// crash gate's `debug.crash.app {"signal": "suspended"}` (only the
    /// ``CrashWatcher`` can then end a blocked crash path).
    static func suspendThread() {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return }
        defer {
            for index in 0 ..< Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        for index in 0 ..< Int(count) where name(of: threads[index]) == threadName {
            _ = thread_suspend(threads[index])
        }
    }

    private static let threadName = "cmux-next crash deadline"

    private static func name(of thread: thread_act_t) -> String? {
        var info = thread_extended_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func watch(_ semaphore: semaphore_t) {
        // concurrency-allow: dedicated crash-deadline thread, parked until a crash path arms it; never the main thread.
        var result = semaphore_wait(semaphore)
        while result == KERN_ABORTED { result = semaphore_wait(semaphore) }
        guard result == KERN_SUCCESS else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = seconds * 1_000_000_000 * UInt64(timebase.denom) / UInt64(max(timebase.numer, 1))
        let deadline = mach_absolute_time() + ticks
        // concurrency-allow: dedicated crash-deadline thread; the intentional bounded wait of a crash in progress.
        while mach_wait_until(deadline) == KERN_ABORTED {}
        guard !isBeingDebugged() else { return }
        end()
    }

    /// Ends the process now with a system crash report.
    private static func end() {
        // A trap that runs again must reach the system's handler, not a dead one.
        TaskExceptionPorts.restoreIfSentryOwned()
        _ = signal(SIGABRT, SIG_DFL)
        abort()
    }

    /// Whether a debugger traces this process (a developer inspecting a
    /// crash must not lose the process to the deadline).
    private static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A tuple on the stack: no allocation after the arm.
        var name: (Int32, Int32, Int32, Int32) = (CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid())
        let result = withUnsafeMutableBytes(of: &name) { raw in
            sysctl(raw.baseAddress?.assumingMemoryBound(to: Int32.self), 4, &info, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}

// Written once on the main thread before any handler can arm it, read-only
// after (a signal handler reads it, so a plain global with a constant initial value).
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var deadlineSemaphore: semaphore_t = 0
