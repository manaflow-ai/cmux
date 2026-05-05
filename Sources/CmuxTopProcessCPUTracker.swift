import Darwin
import Foundation

struct CmuxTopProcessCPUSample: Sendable {
    let totalTimeTicks: UInt64
    let sampledAtNanoseconds: UInt64
}

// CmuxTopProcessSnapshot.capture is intentionally synchronous because it backs
// both async task-manager sampling and sync v2 system.top socket handling. Keep
// this tiny lock isolated to dictionary reads/writes; proc/sysctl work must
// happen outside the critical section.
private final class CmuxTopCPUSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]

    func previousSamplesForCapture() -> [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func recordSamples(
        _ currentSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        sampledAtNanoseconds: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }

        for (key, sample) in currentSamples {
            guard activeKeys.contains(key) else { continue }
            if let existing = samples[key],
               existing.sampledAtNanoseconds > sample.sampledAtNanoseconds {
                continue
            }
            samples[key] = sample
        }

        samples = samples.filter { entry in
            activeKeys.contains(entry.key) || entry.value.sampledAtNanoseconds > sampledAtNanoseconds
        }
    }
}

private let cmuxTopCPUSampleStore = CmuxTopCPUSampleStore()
private let cmuxTopAbsoluteTimeNanosecondsRatio: Double = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else {
        return 1
    }
    return Double(info.numer) / Double(info.denom)
}()

extension CmuxTopProcessSnapshot {
    static func cpuSampleClockNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func previousCPUSamplesForCapture() -> [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] {
        cmuxTopCPUSampleStore.previousSamplesForCapture()
    }

    static func recordCPUSamples(
        _ samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>,
        sampledAtNanoseconds: UInt64
    ) {
        cmuxTopCPUSampleStore.recordSamples(
            samples,
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

        let cpuNanoseconds = absoluteTimeNanoseconds(cpuDelta)
        let wallNanoseconds = Double(wallDeltaNanoseconds)

        return max(0, cpuNanoseconds / wallNanoseconds * 100.0)
    }

    private static func clampedCPUTimeTicks(_ user: UInt64, _ system: UInt64) -> UInt64 {
        let (sum, overflow) = user.addingReportingOverflow(system)
        return overflow ? UInt64.max : sum
    }

    private static func absoluteTimeNanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * cmuxTopAbsoluteTimeNanosecondsRatio
    }
}
