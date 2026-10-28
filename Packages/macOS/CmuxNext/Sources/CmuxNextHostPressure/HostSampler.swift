import Darwin
import Foundation
import CmuxNextCompat

/// Reads this Mac's numbers the way the host budget does: the performance
/// cores (`performanceCores`), the 1-minute load and the swap-out counter.
/// The memory pressure level is not read here: it comes from the app's one
/// `MemoryPressureEvents` (see `HostPressureMonitor`). Each read is one
/// syscall; nothing here polls on its own.
public struct HostSampler: Sendable {
    public init() {}

    /// The cores the budget counts and their kind, as acpmux counts them:
    /// "performance" (else "physical"), or "logical" (every CPU).
    public func cores(_ which: String) -> (count: Int, kind: String) {
        let logical = (max(1, ProcessInfo.processInfo.activeProcessorCount), "logical")
        guard which == "performance" else { return logical }
        if let count = Self.performanceCores(int: Self.sysctlInt32, string: Self.sysctlString) { return (count, "performance") }
        if let count = Self.sysctlInt32("hw.physicalcpu"), count > 0 { return (Int(count), "physical") }
        return logical
    }

    /// Every core that is not an efficiency core: the sum of
    /// hw.perflevelN.physicalcpu for N under hw.nperflevels whose
    /// hw.perflevelN.name is not "Efficiency" (the host-budget contract). On
    /// M5 and later, perflevel0 is only the "Super" tier, so it alone undercounts
    /// (cosmic-gray: Super 5 + Performance 10). Nil when the levels are unreadable.
    public static func performanceCores(int: (String) -> Int32?, string: (String) -> String?) -> Int? {
        guard let levels = int("hw.nperflevels"), levels > 0 else { return nil }
        var total = 0
        for level in 0 ..< Int(levels) {
            guard let count = int("hw.perflevel\(level).physicalcpu"), count >= 0 else { return nil }
            if string("hw.perflevel\(level).name") != "Efficiency" { total += Int(count) }
        }
        return total > 0 ? total : nil
    }

    /// The share of RAM available (kern.memorystatus_level, the "System-wide
    /// memory free percentage" memory_pressure prints), nil when unreadable.
    public func availableRAMFraction() -> Double? {
        Self.sysctlInt32("kern.memorystatus_level").map { Double($0) / 100 }
    }

    /// This Mac's name from kern.hostname (never a blocking name lookup).
    public func hostName() -> String {
        Self.sysctlString("kern.hostname") ?? "localhost"
    }

    public func load1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// Bytes swapped out since boot (vm_stat's Swapouts, in bytes).
    public func swappedOutBytes() -> UInt64? {
        Self.vmStatistics().map { $0.swapouts &* UInt64(getpagesize()) }
    }

    /// Free physical memory as Chrome counts it on Apple platforms (base/system/sys_info_apple.mm,
    /// `AmountOfAvailablePhysicalMemory`: free plus speculative pages, which `free_count` holds), in bytes.
    public func freePhysicalBytes() -> UInt64? {
        Self.vmStatistics().map { UInt64($0.free_count) &* UInt64(getpagesize()) }
    }

    /// One `host_statistics64` call; nil when it fails.
    private static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// One send right for the process's life: each `mach_host_self()` adds a
    /// user reference that is never released.
    private static let hostPort = mach_host_self()

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return blockingSysctlByName(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard blockingSysctlByName(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard blockingSysctlByName(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The swap-out rate between two reads of the counter.
public struct SwapRate: Sendable {
    private var last: (bytes: UInt64, seconds: Double)?

    public init() {}

    /// MB a minute since the previous read; nil on the first one or after the
    /// counter went back (acpmux's `swap_mb_per_min` is null until two samples too).
    public mutating func feed(bytes: UInt64, seconds: Double) -> Double? {
        defer { last = (bytes, seconds) }
        guard let last, seconds > last.seconds, bytes >= last.bytes else { return nil }
        return Double(bytes - last.bytes) / 1_048_576 / ((seconds - last.seconds) / 60)
    }
}
