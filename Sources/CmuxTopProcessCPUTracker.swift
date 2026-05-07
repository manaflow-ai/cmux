import Darwin
import Foundation
import os

nonisolated struct CmuxTopProcessCPUSample: Sendable {
    let totalTimeTicks: UInt64
    let sampledAtNanoseconds: UInt64
}

private nonisolated struct CmuxTopProcessCPUTrackerState: Sendable {
    var samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
    var latestPrunedAtNanoseconds: UInt64 = 0
}

private nonisolated final class CmuxTopProcessCPUTracker: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CmuxTopProcessCPUTrackerState())

    // Snapshot capture is synchronous for the v2 socket path, so an actor would
    // force that caller to block on async state. Keep OS sampling outside this
    // owner and serialize only the CPU history read/compute/write transaction.
    func cpuPercentages(
        for currentSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        sampledAtNanoseconds: UInt64
    ) -> [CmuxTopProcessScopeCacheKey: Double] {
        state.withLock { state in
            var percentages: [CmuxTopProcessScopeCacheKey: Double] = [:]
            percentages.reserveCapacity(currentSamples.count)

            for (key, sample) in currentSamples {
                let existing = state.samples[key]
                if let existing,
                   existing.sampledAtNanoseconds > sample.sampledAtNanoseconds {
                    continue
                }

                percentages[key] = CmuxTopProcessSnapshot.cpuPercent(
                    current: sample,
                    previous: existing
                )
                state.samples[key] = sample
            }

            // Overlapping captures can finish out of sample-time order; only
            // the newest completed capture is allowed to evict inactive keys.
            if sampledAtNanoseconds >= state.latestPrunedAtNanoseconds {
                state.latestPrunedAtNanoseconds = sampledAtNanoseconds
                state.samples = state.samples.filter { entry in
                    activeKeys.contains(entry.key)
                }
            }

            return percentages
        }
    }
}

private nonisolated let cmuxTopProcessCPUTracker = CmuxTopProcessCPUTracker()
private nonisolated let cmuxTopAbsoluteTimeNanosecondsRatio: Double? = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else {
        return nil
    }
    return Double(info.numer) / Double(info.denom)
}()

nonisolated extension CmuxTopProcessSnapshot {
    static func cpuSampleClockNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func cpuPercentages(
        for samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        sampledAtNanoseconds: UInt64
    ) -> [CmuxTopProcessScopeCacheKey: Double] {
        cmuxTopProcessCPUTracker.cpuPercentages(
            for: samples,
            activeKeys: activeKeys,
            sampledAtNanoseconds: sampledAtNanoseconds
        )
    }

    static func cpuSample(
        from taskInfo: proc_taskinfo,
        sampledAtNanoseconds: UInt64
    ) -> CmuxTopProcessCPUSample {
        CmuxTopProcessCPUSample(
            totalTimeTicks: clampedCPUTimeTicks(taskInfo.pti_total_user, taskInfo.pti_total_system),
            sampledAtNanoseconds: sampledAtNanoseconds
        )
    }

    static func cpuPercent(
        current: CmuxTopProcessCPUSample,
        previous: CmuxTopProcessCPUSample?
    ) -> Double {
        guard let previous,
              current.sampledAtNanoseconds > previous.sampledAtNanoseconds,
              current.totalTimeTicks >= previous.totalTimeTicks,
              current.totalTimeTicks != UInt64.max,
              previous.totalTimeTicks != UInt64.max else {
            return 0
        }

        let cpuDelta = current.totalTimeTicks - previous.totalTimeTicks
        let wallDeltaNanoseconds = current.sampledAtNanoseconds - previous.sampledAtNanoseconds
        guard wallDeltaNanoseconds > 0 else { return 0 }

        guard let cpuNanoseconds = absoluteTimeNanoseconds(cpuDelta) else { return 0 }
        let wallNanoseconds = Double(wallDeltaNanoseconds)

        return max(0, cpuNanoseconds / wallNanoseconds * 100.0)
    }

    private static func clampedCPUTimeTicks(_ user: UInt64, _ system: UInt64) -> UInt64 {
        let (sum, overflow) = user.addingReportingOverflow(system)
        return overflow ? UInt64.max : sum
    }

    private static func absoluteTimeNanoseconds(_ ticks: UInt64) -> Double? {
        guard let ratio = cmuxTopAbsoluteTimeNanosecondsRatio else { return nil }
        return Double(ticks) * ratio
    }
}
