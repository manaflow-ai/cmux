import Darwin

/// Process CPU time and memory, read from the kernel. Both link ends run in
/// this process, so CPU covers sender and receiver together.
struct ProcessUsage: Sendable {
    /// User plus system CPU seconds so far (getrusage).
    var cpuSeconds: Double
    /// Resident high-water mark in bytes (ru_maxrss, bytes on Darwin).
    var maxResidentBytes: Int
    /// Current physical footprint in bytes (task_vm_info), what jetsam counts on iOS.
    var footprintBytes: Int

    init() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
        cpuSeconds = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        maxResidentBytes = Int(usage.ru_maxrss)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        footprintBytes = result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
