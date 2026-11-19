import Darwin
import Foundation

/// Experiment (lane/rtc-premain-a, not for merge): what this process did between its start and `main`, read
/// once when the launch-mark sink is first made (the `main_start` mark): CPU time in user and kernel space,
/// page-ins, bytes read and how many images dyld had loaded. Each is written as a `premain.*` launch mark
/// whose value is the number.
nonisolated struct PremainUsage {
    func marks() -> [(String, Double)] {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        let now = mach_absolute_time()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ms(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000 }
        var result: [(String, Double)] = [("premain.images", Double(_dyld_image_count()))]
        var events = task_events_info()
        let words = MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(truncatingIfNeeded: words)
        let eventsStatus = withUnsafeMutablePointer(to: &events) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: words) { task_info(mach_task_self_, task_flavor_t(truncatingIfNeeded: TASK_EVENTS_INFO), $0, &count) }
        }
        if eventsStatus == KERN_SUCCESS {
            result += [
                ("premain.mach_messages_sent", Double(events.messages_sent)),
                ("premain.mach_messages_received", Double(events.messages_received)),
                ("premain.context_switches", Double(events.csw)),
                ("premain.syscalls_unix", Double(events.syscalls_unix)),
                ("premain.syscalls_mach", Double(events.syscalls_mach)),
            ]
        }
        guard status == 0 else { return result }
        result += [
            ("premain.user_ms", ms(info.ri_user_time)),
            ("premain.system_ms", ms(info.ri_system_time)),
            ("premain.pageins", Double(info.ri_pageins)),
            ("premain.diskio_read_kib", Double(info.ri_diskio_bytesread) / 1_024),
            ("premain.abstime_since_start_ms", ms(now &- info.ri_proc_start_abstime)),
        ]
        return result
    }
}
