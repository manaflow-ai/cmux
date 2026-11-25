import CmuxNextWakeups
import Foundation

extension ProcessSample {
    /// Samples this Mac's `pids` (`proc_pid_rusage`) off the main actor; a gone or foreign pid is
    /// left out. The hover cards, `resources` and the Task Manager share it.
    @concurrent
    public static func sampleLocal(_ pids: [Int32]) async -> [ProcessKey: ProcessSample] {
        var samples: [ProcessKey: ProcessSample] = [:]
        for pid in pids {
            guard let usage = ProcessUsage.sample(pid) else { continue }
            let key = ProcessKey(pid: pid)
            samples[key] = ProcessSample(key: key, name: usage.name, cpuNanos: usage.cpuNanos,
                                         memoryBytes: usage.physFootprint, sampledAtNanos: usage.uptimeNanos)
        }
        return samples
    }
}
