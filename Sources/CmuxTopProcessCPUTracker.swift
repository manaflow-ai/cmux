import Darwin
import Foundation

struct CmuxTopProcessCPUSample: Sendable {
    let totalTimeTicks: UInt64
    let sampledAtNanoseconds: UInt64
}

private let cmuxTopCPUSampleLock = NSLock()
private var cmuxTopCPUSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
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
        cmuxTopCPUSampleLock.lock()
        let samples = cmuxTopCPUSamples
        cmuxTopCPUSampleLock.unlock()
        return samples
    }

    static func recordCPUSamples(
        _ samples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample],
        activeKeys: Set<CmuxTopProcessScopeCacheKey>
    ) {
        cmuxTopCPUSampleLock.lock()
        var nextSamples = cmuxTopCPUSamples.filter { activeKeys.contains($0.key) }
        for (key, sample) in samples {
            guard activeKeys.contains(key) else { continue }
            if let existing = nextSamples[key],
               existing.sampledAtNanoseconds > sample.sampledAtNanoseconds {
                continue
            }
            nextSamples[key] = sample
        }
        cmuxTopCPUSamples = nextSamples
        cmuxTopCPUSampleLock.unlock()
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
              current.totalTimeTicks >= previous.totalTimeTicks else {
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
