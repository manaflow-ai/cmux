#if DEBUG || CMUX_BENCH_HOOKS
import Darwin

/// The process's threads, for ``StartupReport/FirstFrame/threads``. Tests give their own list.
public nonisolated protocol StartupThreadSource: Sendable {
    func threads() -> [StartupReport.ThreadRecord]
}

/// The kernel's thread list: `task_threads`, then each thread's `THREAD_IDENTIFIER_INFO` and
/// `THREAD_EXTENDED_INFO` (the name and priority the kernel holds, with no pthread lock). Read-only: no
/// thread is suspended. Any thread may call ``threads()``; the main thread is the one ``init()`` ran on.
public nonisolated struct SystemStartupThreads: StartupThreadSource {
    /// The main thread's system-wide id (`pthread_threadid_np`), read on the main actor at init: the SDK has
    /// no public call that names the main thread from another thread.
    private let mainThreadID: UInt64

    /// Call it on the main actor, which names the main thread's row (as `debug.threads` does).
    @MainActor
    public init() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        mainThreadID = id
    }

    public func threads() -> [StartupReport.ThreadRecord] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        let ports = UnsafeBufferPointer(start: list, count: Int(truncatingIfNeeded: count))
        defer {
            for port in ports { mach_port_deallocate(mach_task_self_, port) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(truncatingIfNeeded: ports.count * MemoryLayout<thread_act_t>.stride))
        }
        return ports.compactMap { port in
            guard let id = Self.identifier(port), let extended = Self.extended(port) else { return nil }
            return StartupReport.ThreadRecord(id: id, name: extended.name, priority: extended.priority,
                                              isMain: id == mainThreadID)
        }
    }

    private static func identifier(_ port: thread_act_t) -> UInt64? {
        var info = thread_identifier_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(truncatingIfNeeded: count)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.thread_id : nil
    }

    private static func extended(_ port: thread_act_t) -> (name: String, priority: Int32)? {
        var info = thread_extended_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(truncatingIfNeeded: count)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let name = withUnsafeBytes(of: &info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name, info.pth_curpri)
    }
}
#endif
