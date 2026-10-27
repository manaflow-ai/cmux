/// One platform's raw host numbers for ``HostSampler``: sysctl and Mach on macOS
/// (`DarwinHostReadings`), /proc on Linux (`ProcHostReadings`). Each read is one
/// syscall or one /proc file; nil when the platform has no such number or it is
/// unreadable.
protocol HostReadings: Sendable {
    /// The cores of every perf level not named Efficiency (``HostSampler/performanceCores(int:string:)``).
    func performanceCores() -> Int?
    func physicalCores() -> Int?
    /// The share of RAM available, 0 to 1.
    func availableRAMFraction() -> Double?
    /// The kernel's host name.
    func hostName() -> String?
    /// Bytes swapped out since boot.
    func swappedOutBytes() -> UInt64?
    /// The memory pressure the host reports with its other numbers (Linux PSI at or over
    /// `psiThreshold` is warn); nil where an event feed reports it (macOS `MemoryPressureEvents`).
    func memoryPressure(psiThreshold: Double) -> HostMemoryPressure?
}
