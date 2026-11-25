import CmuxNextCompat
import Darwin

/// Jobs a component ran on a ``BackgroundWork`` lane and their thread CPU time (`CLOCK_THREAD_CPUTIME_ID`): what it
/// costs that lane, for benches and `debug.timings`.
nonisolated struct LaneCost: Sendable, Equatable {
    var jobs = 0
    var cpuNanos: UInt64 = 0
    var cpuMilliseconds: Double { Double(cpuNanos) / 1e6 }
}

/// Counts one component's ``LaneCost``; owned by that component, never shared.
nonisolated final class LaneCostMeter: Sendable {
    private let cost = Mutex(LaneCost())

    var total: LaneCost { cost.withLock { $0 } }

    /// Runs `body` on the calling thread and adds it as one job.
    @discardableResult
    func measure<T>(_ body: () -> T) -> T {
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = body()
        let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- started
        cost.withLock { $0.jobs += 1; $0.cpuNanos &+= spent }
        return result
    }
}
