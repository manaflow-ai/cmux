import Darwin

/// This task's threads as the kernel lists them: the one owner of the `task_threads` port list's lifetime and of
/// `thread_info` reads, shared by the hang sampler (``ThreadStackSampler``) and `debug.threads`.
struct MachThreads {
    /// Runs `body` over this task's thread ports, then releases each port and the list; `body` sees an empty
    /// list when the kernel does not answer. A port is valid only inside `body`.
    static func withTaskThreads<Result>(_ body: (UnsafeBufferPointer<thread_act_t>) -> Result) -> Result {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return body(UnsafeBufferPointer(start: nil, count: 0))
        }
        let threads = UnsafeBufferPointer(start: list, count: Int(truncatingIfNeeded: count))
        defer {
            for thread in threads { mach_port_deallocate(mach_task_self_, thread) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(truncatingIfNeeded: threads.count * MemoryLayout<thread_act_t>.stride))
        }
        return body(threads)
    }

    /// One `thread_info` flavor of `thread`; nil when the thread exited or the kernel refused.
    ///
    /// - Parameters:
    ///   - thread: The thread's port.
    ///   - flavor: `THREAD_IDENTIFIER_INFO`, `THREAD_EXTENDED_INFO`, ...
    ///   - empty: A zero value of the flavor's struct.
    static func info<Info>(_ thread: thread_act_t, _ flavor: Int32, _ empty: Info) -> Info? {
        var info = empty
        var count = mach_msg_type_number_t(MemoryLayout<Info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(truncatingIfNeeded: count)) {
                thread_info(thread, thread_flavor_t(flavor), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// The kernel's copy of the thread's name (`THREAD_EXTENDED_INFO` `pth_name`, read with no pthread lock).
    static func name(of extended: thread_extended_info_data_t) -> String {
        withUnsafeBytes(of: extended.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The thread's name; empty when unnamed or unreadable.
    static func name(_ thread: thread_act_t) -> String {
        info(thread, THREAD_EXTENDED_INFO, thread_extended_info_data_t()).map(name(of:)) ?? ""
    }
}
