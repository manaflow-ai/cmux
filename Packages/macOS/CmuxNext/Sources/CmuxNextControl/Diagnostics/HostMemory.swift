import Darwin

/// The host's memory counters: swap in use, compressed and free pages, page-ins since boot and
/// the kernel's memory pressure level. A starved hang's main thread sits at 0-2% CPU parked in
/// page-ins (field-hang-seconds-tenth): these say whether the Mac was short of memory (swap
/// growing, pages read back from disk) or only short of CPU.
public struct HostMemory: Sendable, Equatable {
    /// Swap in use, bytes (`vm.swapusage`).
    public var swapUsed: UInt64
    /// Pages the compressor holds (`HOST_VM_INFO64` `compressor_page_count`).
    public var compressedPages: UInt64
    /// Free pages (`free_count`).
    public var freePages: UInt64
    /// Host page-ins since boot (`pageins`): pages read from disk or swap by every process.
    public var pageIns: UInt64
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical; 0 unknown.
    public var pressureLevel: Int32

    public init(swapUsed: UInt64, compressedPages: UInt64, freePages: UInt64, pageIns: UInt64, pressureLevel: Int32) {
        self.swapUsed = swapUsed
        self.compressedPages = compressedPages
        self.freePages = freePages
        self.pageIns = pageIns
        self.pressureLevel = pressureLevel
    }

    /// The host's counters now; nil when `host_statistics64` fails. Three syscalls of a few
    /// microseconds, no allocation: the watchdog thread reads it once at a stall's first sample
    /// and once per hang file update, never per heartbeat.
    static func current() -> HostMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) != 0 { level = 0 }
        return HostMemory(swapUsed: swapUsed, compressedPages: UInt64(clamping: stats.compressor_page_count),
                          freePages: UInt64(clamping: stats.free_count), pageIns: UInt64(clamping: stats.pageins), pressureLevel: level)
    }

    /// One send right for the process's life: each `mach_host_self()` call adds a reference.
    private static let hostPort = mach_host_self()
}

/// The host's memory over a stall: its state at the end and what changed since the stall's
/// first sample (``HangLoad/memory``).
public struct HostMemoryDelta: Sendable, Equatable {
    /// The counters at the latest sample.
    public var now: HostMemory
    /// Swap growth over the stall, bytes; negative when swap shrank.
    public var swapGrowth: Int64
    /// Host page-ins over the stall.
    public var pageIns: UInt64

    public init(now: HostMemory, swapGrowth: Int64, pageIns: UInt64) {
        self.now = now
        self.swapGrowth = swapGrowth
        self.pageIns = pageIns
    }

    /// From `start` (the stall's first sample) to `now`.
    public init(from start: HostMemory, to now: HostMemory) {
        self.init(now: now, swapGrowth: Int64(clamping: now.swapUsed) &- Int64(clamping: start.swapUsed),
                  pageIns: now.pageIns &- min(start.pageIns, now.pageIns))
    }

    /// Host page-ins per second of stall at or above which the Mac was paging hard: 2,000
    /// 16 KiB pages a second is 32 MiB/s read back from disk or swap, far above an idle Mac's
    /// trickle, and at cmux#27587's 86 ms p99 uncached read under load a main thread that
    /// needs a few of those pages waits seconds.
    static let pressuredHostPageInsPerSecond = 2_000.0
    /// This process's page-ins over a stall at or above which its own wait on the disk can
    /// explain a hang: 50 serial reads at 86 ms (cmux#27587's loaded p99) are over 4 s.
    static let pressuredProcessPageIns: UInt64 = 50

    /// Short of memory over a stall `duration` long in which this process paged in
    /// `processPageIns` (nil when unknown): swap grew, the kernel's pressure level was warning
    /// or critical, or the host or this process paged in past the thresholds above.
    func isPressured(duration: Duration, processPageIns: UInt64?) -> Bool {
        if swapGrowth > 0 || now.pressureLevel >= 2 { return true }
        if let processPageIns, processPageIns >= Self.pressuredProcessPageIns { return true }
        let seconds = duration.fractionalMilliseconds / 1_000
        return seconds > 0 && Double(pageIns) / seconds >= Self.pressuredHostPageInsPerSecond
    }

    /// `host memory: swap 2.1 GB (+180.0 MB), compressed 412000, free 3100 pages, host page-ins 9400, pressure warning (pressured)`.
    func line(duration: Duration, processPageIns: UInt64?) -> String {
        let growth = swapGrowth == 0 ? "" : " (\(swapGrowth > 0 ? "+" : "-")\(bytes(swapGrowth.magnitude)))"
        let pressure = switch now.pressureLevel {
        case 1: "normal"
        case 2: "warning"
        case 4: "critical"
        default: "unknown"
        }
        return "host memory: swap \(bytes(now.swapUsed))\(growth), compressed \(now.compressedPages), free \(now.freePages) pages, "
            + "host page-ins \(pageIns), pressure \(pressure)"
            + (isPressured(duration: duration, processPageIns: processPageIns) ? " (pressured)" : "")
    }
}

/// `2.1 GB`, `180.0 MB`, decimal units.
private func bytes(_ count: UInt64) -> String {
    let value = Double(count)
    if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
    return String(format: "%.1f MB", value / 1e6)
}
