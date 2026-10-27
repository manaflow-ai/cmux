#if canImport(Darwin)
import Darwin

/// macOS's host numbers: sysctl and the Mach VM counters, one syscall each.
/// The memory pressure level comes from the app's `MemoryPressureEvents`, not from here.
struct DarwinHostReadings: HostReadings {
    func performanceCores() -> Int? {
        HostSampler.performanceCores(int: Self.sysctlInt32, string: Self.sysctlString)
    }

    func physicalCores() -> Int? {
        Self.sysctlInt32("hw.physicalcpu").map(Int.init)
    }

    /// kern.memorystatus_level, the "System-wide memory free percentage" memory_pressure prints.
    func availableRAMFraction() -> Double? {
        Self.sysctlInt32("kern.memorystatus_level").map { Double($0) / 100 }
    }

    func hostName() -> String? {
        Self.sysctlString("kern.hostname")
    }

    /// vm_stat's Swapouts, in bytes.
    func swappedOutBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats.swapouts &* UInt64(getpagesize())
    }

    func memoryPressure(psiThreshold: Double) -> HostMemoryPressure? {
        nil
    }

    /// One send right for the process's life: each `mach_host_self()` adds a
    /// user reference that is never released.
    private static let hostPort = mach_host_self()

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
