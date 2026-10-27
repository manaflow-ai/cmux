#if os(Linux)
import CmuxNextCompat
public import Glibc
import Foundation

// The Linux readers of ProcessUsage (p15-oracle-126): `/proc` in place of proc_pid_rusage and libproc,
// with the counters Chromium reads there (base/process/process_metrics_linux.cc):
// - CPU time: utime + stime of /proc/<pid>/stat, in clock ticks (`GetCumulativeCPUUsage`);
// - wakeups: voluntary_ctxt_switches of /proc/<pid>/status (`GetIdleWakeupsPerSecond`). Linux has no
//   package-idle counter, so ``ProcessUsage/packageIdleWakeups`` is 0 and ``ProcessUsage/wakeups`` counts
//   each wakeup once;
// - footprint: RssAnon + VmSwap of /proc/<pid>/status (the private footprint of
//   services/resource_coordinator/public/cpp/memory_instrumentation/os_metrics_linux.cc);
// - energy: 0 (no per-process energy counter exists).
// Each read is a few non-blocking procfs reads; call them off the main actor, as on Darwin.
extension ProcessUsage {
    /// Samples `pid`; nil when it is gone or not ours. Blocking syscalls: call it off the main actor.
    public static func sample(_ pid: pid_t) -> ProcessUsage? {
        guard let status = LinuxProcStatus(pid: pid), status.isOurs, let stat = LinuxProcStat(pid: pid) else { return nil }
        return ProcessUsage(pid: pid, parent: stat.parent, path: path(of: pid) ?? "", cpuNanos: stat.cpuNanos,
                            wakeups: status.voluntarySwitches, interruptWakeups: status.voluntarySwitches,
                            packageIdleWakeups: 0, energyNanojoules: 0, physFootprint: status.privateFootprintBytes,
                            uptimeNanos: monotonicNanos())
    }

    /// ``interruptWakeups`` of `pid` alone (its voluntary context switches), from one read of its status
    /// file; nil when it is gone or not ours.
    public static func interruptWakeups(of pid: pid_t) -> UInt64? {
        guard let status = LinuxProcStatus(pid: pid), status.isOurs else { return nil }
        return status.voluntarySwitches
    }

    /// The executable of `pid` (`/proc/<pid>/exe`); nil when it is gone or not readable by us.
    public static func path(of pid: pid_t) -> String? {
        try? FileManager.checked.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }

    /// The argument vector of `pid` (`/proc/<pid>/cmdline`), or [] when unreadable.
    public static func arguments(of pid: pid_t) -> [String] {
        guard let bytes = procFile("/proc/\(pid)/cmdline"), !bytes.isEmpty else { return [] }
        // Each argument ends with a NUL; the last NUL leaves one empty piece behind it.
        var pieces = bytes.split(separator: 0, omittingEmptySubsequences: false)
        if bytes.last == 0 { pieces.removeLast() }
        return pieces.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Direct children of `pid`: every thread's `children` file, as a child belongs to the thread that forked it.
    public static func children(of pid: pid_t) -> [pid_t] {
        let threads = (try? FileManager.checked.contentsOfDirectory(atPath: "/proc/\(pid)/task")) ?? []
        var children: [pid_t] = []
        for thread in threads.sorted() {
            guard let bytes = procFile("/proc/\(pid)/task/\(thread)/children") else { continue }
            children += String(decoding: bytes, as: UTF8.self).split(separator: " ").compactMap { pid_t($0) }.filter { $0 > 0 }
        }
        return children
    }

    /// Every process of this user whose executable path starts with `prefix`.
    public static func processes(pathPrefix prefix: String) -> [pid_t] {
        let entries = (try? FileManager.checked.contentsOfDirectory(atPath: "/proc")) ?? []
        let uid = getuid()
        // The path first: another user's exe link is unreadable, so most processes stop there.
        return entries.compactMap { pid_t($0) }.sorted().filter { pid in
            pid > 0 && (path(of: pid)?.hasPrefix(prefix) ?? false) && LinuxProcStatus(pid: pid)?.effectiveUID == uid
        }
    }

    /// `CLOCK_MONOTONIC` nanoseconds: like Darwin's `CLOCK_UPTIME_RAW`, it does not count suspend.
    static func monotonicNanos() -> UInt64 {
        var now = timespec()
        // SAFETY: clock_gettime writes one timespec into `now`, a local live for the call.
        _ = unsafe clock_gettime(CLOCK_MONOTONIC, &now)
        return UInt64(now.tv_sec) &* 1_000_000_000 &+ UInt64(now.tv_nsec)
    }

    /// A whole procfs file (its size reads as 0, so it is read to its end), or nil when it cannot be opened.
    static func procFile(_ path: String) -> [UInt8]? {
        blockingCall(.fileIO) {
            // SAFETY: open reads `path` as a C string Swift keeps alive for the call.
            let fd = unsafe open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var contents: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                // SAFETY: read writes at most chunk.count bytes into `chunk`, a local array of that size.
                let count = unsafe read(fd, &chunk, chunk.count)
                if count == 0 { return contents }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                contents += chunk.prefix(count)
            }
        }
    }
}

/// The fields of `/proc/<pid>/status` that ``ProcessUsage`` reads.
struct LinuxProcStatus: Equatable {
    var effectiveUID: uid_t
    var voluntarySwitches: UInt64
    /// RssAnon + VmSwap, in bytes (the file says kB).
    var privateFootprintBytes: UInt64

    init?(pid: pid_t) {
        guard let bytes = ProcessUsage.procFile("/proc/\(pid)/status") else { return nil }
        self.init(String(decoding: bytes, as: UTF8.self))
    }

    /// Parses a status file's text; nil without its `Uid:` line.
    init?(_ text: String) {
        var fields: [Substring: [Substring]] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon]] = line[line.index(after: colon)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
        }
        // Uid: real, effective, saved, filesystem.
        guard let uids = fields["Uid"], uids.count >= 2, let effective = uid_t(uids[1]) else { return nil }
        let number = { (key: Substring) in fields[key]?.first.flatMap { UInt64($0) } ?? 0 }
        effectiveUID = effective
        voluntarySwitches = number("voluntary_ctxt_switches")
        privateFootprintBytes = (number("RssAnon") &+ number("VmSwap")) &* 1024
    }

    /// Whether this process may read it as Darwin's proc_pid_rusage would: same user, or root.
    var isOurs: Bool { effectiveUID == getuid() || getuid() == 0 }
}

/// The fields of `/proc/<pid>/stat` that ``ProcessUsage`` reads.
struct LinuxProcStat: Equatable {
    var parent: pid_t
    /// utime + stime, in nanoseconds.
    var cpuNanos: UInt64

    init?(pid: pid_t) {
        guard let bytes = ProcessUsage.procFile("/proc/\(pid)/stat") else { return nil }
        self.init(String(decoding: bytes, as: UTF8.self), ticksPerSecond: UInt64(max(sysconf(Int32(_SC_CLK_TCK)), 1)))
    }

    /// Parses a stat line; nil when it is short. The command name (field 2) may hold spaces and parentheses,
    /// so the fields are counted from the last `)`.
    init?(_ text: String, ticksPerSecond: UInt64) {
        guard let close = text.lastIndex(of: ")") else { return nil }
        // After the name: state (field 3), ppid (4), ... utime (14), stime (15).
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let parent = pid_t(fields[1]), let user = UInt64(fields[11]),
              let system = UInt64(fields[12]), ticksPerSecond > 0 else { return nil }
        self.parent = parent
        cpuNanos = (user &+ system).multipliedReportingOverflow(by: 1_000_000_000).partialValue / ticksPerSecond
    }
}
#endif
