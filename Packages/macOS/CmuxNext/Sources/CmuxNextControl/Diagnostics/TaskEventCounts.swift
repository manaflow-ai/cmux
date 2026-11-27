import Darwin

/// This process's page-fault counters (`task_info` `TASK_EVENTS_INFO`): a hang that pages in
/// a lot was waiting on the disk or swap, not computing.
struct TaskEventCounts: Sendable, Equatable {
    /// Page faults of every kind (zero-fill, copy-on-write, decompression, page-in).
    var faults: UInt64
    /// Faults that read a page from disk or swap.
    var pageIns: UInt64

    /// The current process's counters; nil when `task_info` fails. A syscall of about a
    /// microsecond: the watchdog thread reads it once per stall it samples, never per heartbeat.
    static func current() -> TaskEventCounts? {
        var info = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return TaskEventCounts(faults: UInt64(clamping: info.faults), pageIns: UInt64(clamping: info.pageins))
    }

    /// The load from `self` (the stall's first sample) to `now`, with the main thread's `cpu`.
    func load(to now: TaskEventCounts?, cpu: Duration?) -> HangLoad {
        guard let now else { return HangLoad(mainThreadCPU: cpu) }
        return HangLoad(mainThreadCPU: cpu, pageIns: now.pageIns &- min(pageIns, now.pageIns),
                        faults: now.faults &- min(faults, now.faults))
    }
}
