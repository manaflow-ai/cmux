import Darwin
import Foundation

/// Reads this Mac's numbers the way the host budget does: the performance
/// cores (hw.perflevel0.physicalcpu), the 1-minute load, the memory pressure
/// level and the swap-out counter. Each read is one syscall; nothing here
/// polls on its own.
public struct HostSampler: Sendable {
    public init() {}

    /// The cores the budget counts ("performance", else every physical core).
    public func cores(_ which: String) -> Int {
        if which == "performance", let count = Self.sysctlInt32("hw.perflevel0.physicalcpu"), count > 0 { return Int(count) }
        return Int(Self.sysctlInt32("hw.physicalcpu") ?? Int32(ProcessInfo.processInfo.activeProcessorCount))
    }

    /// This Mac's name from kern.hostname (never a blocking name lookup).
    public func hostName() -> String {
        var size = 0
        guard sysctlbyname("kern.hostname", nil, &size, nil, 0) == 0, size > 0 else { return "localhost" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.hostname", &bytes, &size, nil, 0) == 0 else { return "localhost" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func load1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    public func memoryPressure() -> HostMemoryPressure {
        HostMemoryPressure(sysctlLevel: Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    /// Bytes swapped out since boot (vm_stat's Swapouts, in bytes).
    public func swappedOutBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats.swapouts &* UInt64(vm_kernel_page_size)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
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
