import Darwin
import Foundation
import os

struct CmuxTopProcessCPUSample: Sendable {
    let totalTimeTicks: UInt64
    let sampledAtNanoseconds: UInt64
}

private struct CmuxTopProcessCPUTrackerState: Sendable {
    var entries: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUTrackerEntry] = [:]
    var latestPrunedAtNanoseconds: UInt64 = 0
}

private struct CmuxTopProcessCPUTrackerEntry: Sendable {
    let sample: CmuxTopProcessCPUSample
    let cpuPercent: Double
    let parentKey: CmuxTopProcessScopeCacheKey?
}

private final class CmuxTopProcessCPUTracker: @unchecked Sendable {
    private static let minimumSampleWindowNanoseconds: UInt64 = 1_000_000_000

    private let state = OSAllocatedUnfairLock(initialState: CmuxTopProcessCPUTrackerState())

    // Snapshot capture is synchronous for the v2 socket path, so an actor would
    // force that caller to block on async state. Keep OS sampling outside this
    // owner and serialize only the CPU history read/compute/write transaction.
    func cpuPercentages(
        for currentSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        parentKeysByKey: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey],
        sampledAtNanoseconds: UInt64
    ) -> [CmuxTopProcessScopeCacheKey: Double] {
        state.withLock { state in
            var percentages: [CmuxTopProcessScopeCacheKey: Double] = [:]
            percentages.reserveCapacity(currentSamples.count)
            var heldKeys: Set<CmuxTopProcessScopeCacheKey> = []

            for (key, sample) in currentSamples {
                let parentKey = parentKeysByKey[key]
                let existing = state.entries[key]
                if let existing,
                   existing.sample.sampledAtNanoseconds > sample.sampledAtNanoseconds {
                    percentages[key] = existing.cpuPercent
                    heldKeys.insert(key)
                    continue
                }

                if let existing {
                    let elapsedNanoseconds = sample.sampledAtNanoseconds - existing.sample.sampledAtNanoseconds
                    guard elapsedNanoseconds >= Self.minimumSampleWindowNanoseconds else {
                        percentages[key] = existing.cpuPercent
                        heldKeys.insert(key)
                        if existing.parentKey != parentKey {
                            state.entries[key] = CmuxTopProcessCPUTrackerEntry(
                                sample: existing.sample,
                                cpuPercent: existing.cpuPercent,
                                parentKey: parentKey
                            )
                        }
                        continue
                    }
                }

                let cpuPercent = CmuxTopProcessSnapshot.cpuPercent(
                    current: sample,
                    previous: existing?.sample
                )
                percentages[key] = cpuPercent
                state.entries[key] = CmuxTopProcessCPUTrackerEntry(
                    sample: sample,
                    cpuPercent: cpuPercent,
                    parentKey: parentKey
                )
            }

            for (key, entry) in state.entries where entry.cpuPercent > 0 {
                guard let parentKey = entry.parentKey,
                      !activeKeys.contains(key),
                      activeKeys.contains(parentKey),
                      !heldKeys.contains(parentKey) else {
                    continue
                }
                percentages[parentKey, default: 0] += entry.cpuPercent
            }

            // Overlapping captures can finish out of sample-time order; only
            // the newest completed capture is allowed to evict inactive keys.
            if sampledAtNanoseconds >= state.latestPrunedAtNanoseconds {
                state.latestPrunedAtNanoseconds = sampledAtNanoseconds
                state.entries = state.entries.filter { entry in
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

extension CmuxTopProcessSnapshot {
    static func cpuSampleClockNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func cpuPercentages(
        for samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        parentKeysByKey: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey] = [:],
        sampledAtNanoseconds: UInt64
    ) -> [CmuxTopProcessScopeCacheKey: Double] {
        cmuxTopProcessCPUTracker.cpuPercentages(
            for: samples,
            activeKeys: activeKeys,
            parentKeysByKey: parentKeysByKey,
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
