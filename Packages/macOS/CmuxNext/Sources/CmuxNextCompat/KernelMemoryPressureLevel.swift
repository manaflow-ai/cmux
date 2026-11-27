import Darwin

/// The kernel's memory pressure level right now (`kern.memorystatus_vm_pressure_level`), read once
/// when something needs it at a single moment: when a page's content process ended, was the Mac
/// short of memory?
///
/// ``MemoryPressureEvents`` follows the level as it changes; this reads it on demand, for code that
/// holds no subscription. One `sysctl` call, no allocation.
///
/// ```swift
/// let pressure = KernelMemoryPressureLevel().read()  // .normal, .warning or .critical
/// ```
public struct KernelMemoryPressureLevel: Sendable {
    /// Makes a reader of the system's level.
    public init() {}

    /// The current level; ``MemoryPressureLevel/normal`` when the kernel does not report one.
    public func read() -> MemoryPressureLevel {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else { return .normal }
        return Self.level(kernel: raw)
    }

    /// Maps the kernel's value (`kVMPressureNormal` 1, `kVMPressureWarning` 2, `kVMPressureUrgent` 3,
    /// `kVMPressureCritical` 4) to a ``MemoryPressureLevel``.
    ///
    /// - Parameter kernel: The raw `kern.memorystatus_vm_pressure_level` value.
    /// - Returns: The level; unknown values read as normal.
    public static func level(kernel: Int32) -> MemoryPressureLevel {
        switch kernel {
        case 2: .warning
        case 3, 4: .critical
        default: .normal
        }
    }
}
