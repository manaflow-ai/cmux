import Darwin

/// The process's page-fault counters (`task_events_info`). A Mach call: the watchdog thread reads
/// them, never the main thread (threading-model.md: no syscalls for diagnostics on main).
struct TaskEventCounters: Sendable, Equatable {
    var faults: UInt32
    var pageins: UInt32

    /// The counters now; nil when the kernel refuses the read.
    static func read() -> TaskEventCounters? {
        var info = task_events_info()
        let words = MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(truncatingIfNeeded: words)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return TaskEventCounters(faults: UInt32(bitPattern: info.faults), pageins: UInt32(bitPattern: info.pageins))
    }

    /// The faults and page-ins since `earlier` (the kernel's 32-bit counters wrap).
    func since(_ earlier: TaskEventCounters) -> (faults: UInt64, pageins: UInt64) {
        (UInt64(truncatingIfNeeded: faults &- earlier.faults), UInt64(truncatingIfNeeded: pageins &- earlier.pageins))
    }
}
