public import Darwin
import Foundation

/// CPU time and wakeups of one process (`proc_pid_rusage`), for
/// `debug.wakeups`, the busy watchdog and the idle benchmark. Cumulative
/// since the process started: callers diff two samples for rates.
public struct ProcessUsage: Sendable, Equatable {
    public var pid: pid_t
    public var parent: pid_t
    public var path: String
    /// User plus system CPU time.
    public var cpuNanos: UInt64
    /// Package idle exits plus interrupt wakeups (what Activity Monitor
    /// calls Idle Wake Ups, and timer/IO interrupts).
    public var wakeups: UInt64
    public var physFootprint: UInt64
    public var uptimeNanos: UInt64

    public var name: String { (path as NSString).lastPathComponent }

    /// Samples `pid`; nil when it is gone or not ours.
    public static func sample(_ pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let parent = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? pid_t(bsd.pbi_ppid) : 0
        return ProcessUsage(pid: pid, parent: parent, path: path(of: pid) ?? "", cpuNanos: ticksToNanos(ticks),
                            wakeups: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
                            physFootprint: info.ri_phys_footprint, uptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// CPU share of one core between two samples of the same process (1.0 = 100%).
    public func cpuShare(since earlier: ProcessUsage) -> Double {
        let wall = Double(uptimeNanos &- earlier.uptimeNanos)
        guard wall > 0, cpuNanos >= earlier.cpuNanos else { return 0 }
        return Double(cpuNanos - earlier.cpuNanos) / wall
    }

    /// Wakeups per second between two samples.
    public func wakeupsPerSecond(since earlier: ProcessUsage) -> Double {
        let wall = Double(uptimeNanos &- earlier.uptimeNanos) / 1e9
        guard wall > 0, wakeups >= earlier.wakeups else { return 0 }
        return Double(wakeups - earlier.wakeups) / wall
    }

    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The argument vector of `pid` (KERN_PROCARGS2), or [] when unreadable.
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its NUL padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Direct children of `pid`.
    public static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)).filter { $0 > 0 })
    }

    /// Every process of this user whose executable path starts with `prefix`.
    public static func processes(pathPrefix prefix: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 && (path(of: $0)?.hasPrefix(prefix) ?? false) }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// rusage CPU times are Mach absolute time units.
    static func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0 else { return ticks }
        return ticks.multipliedReportingOverflow(by: UInt64(base.numer)).partialValue / UInt64(base.denom)
    }
}
