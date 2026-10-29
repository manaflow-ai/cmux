#if DEBUG || CMUX_BENCH_HOOKS
import Darwin

/// Bench and debug builds only: a busy stall of `CMUX_NEXT_BENCH_LAUNCH_STALL_MS` (at most 5 s) on
/// the main thread in `main()`, before NSApp exists, so `scripts/cmux-next/bench-launch-stall.py`
/// checks that the watchdog lists a stall from `main()` with its startup phase and task. Unset, it
/// does nothing; a shipped build has no such code.
public struct BenchLaunchStall: Sendable {
    /// The variable that asks for the stall, in milliseconds.
    public static let variable = "CMUX_NEXT_BENCH_LAUNCH_STALL_MS"

    /// How long ``run()`` keeps the main thread busy, in milliseconds (0: not asked for).
    public let milliseconds: Int

    /// Reads ``variable`` from `environment` (a value that is not a whole number is 0).
    public init(environment: [String: String]) {
        milliseconds = min(max(environment[Self.variable].flatMap(Int.init) ?? 0, 0), 5_000)
    }

    /// Spins the calling thread for ``milliseconds`` (CPU, not a sleep: the watchdog sees app work).
    @inline(never)
    public func run() {
        guard milliseconds > 0 else { return }
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ UInt64(clamping: milliseconds) &* 1_000_000
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
    }
}
#endif
