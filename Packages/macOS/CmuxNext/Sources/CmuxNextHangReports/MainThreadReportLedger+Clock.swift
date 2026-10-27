#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension MainThreadReportLedger {
    /// The ledger's default clock: monotonic nanoseconds that do not advance while the machine sleeps, as Chrome's
    /// `TimeTicks` (base/time/time_mac.cc reads mach_absolute_time, base/time/time_now_posix.cc CLOCK_MONOTONIC).
    ///
    /// - Returns: `CLOCK_UPTIME_RAW` on macOS (the clock of `NSEvent.timestamp`), `CLOCK_MONOTONIC` on Linux.
    @Sendable public static func systemUptimeNanos() -> UInt64 {
        #if canImport(Darwin)
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
        var now = timespec()
        // SAFETY: `now` is a local that clock_gettime fills; CLOCK_MONOTONIC always exists on Linux.
        _ = unsafe clock_gettime(CLOCK_MONOTONIC, &now)
        return UInt64(now.tv_sec) &* 1_000_000_000 &+ UInt64(now.tv_nsec)
        #endif
    }
}
