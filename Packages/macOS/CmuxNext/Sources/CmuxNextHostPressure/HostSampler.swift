import Foundation

/// Reads this host's numbers the way the host budget does: the performance
/// cores (`performanceCores`), the 1-minute load, available RAM and the
/// swap-out counter. The platform reads are a ``HostReadings``: sysctl and
/// Mach on macOS, /proc on Linux, as acpmux reads them (cmux-tui
/// host_pressure_probe.rs). On macOS the memory pressure level is not read
/// here: it comes from the app's one `MemoryPressureEvents` (see
/// `HostPressureMonitor`). On Linux it is PSI, read with the other numbers.
/// Each read is one syscall or one /proc file; nothing here polls on its own.
public struct HostSampler: Sendable {
    private let readings: any HostReadings

    public init() {
        #if canImport(Darwin)
        self.init(readings: DarwinHostReadings())
        #else
        self.init(readings: ProcHostReadings(read: ProcHostReadings.readProcFile))
        #endif
    }

    init(readings: any HostReadings) {
        self.readings = readings
    }

    /// The cores the budget counts and their kind, as acpmux counts them:
    /// "performance" (else "physical"), or "logical" (every CPU). Linux has
    /// neither count, so it is logical there, as in acpmux.
    public func cores(_ which: String) -> (count: Int, kind: String) {
        let logical = (max(1, ProcessInfo.processInfo.activeProcessorCount), "logical")
        guard which == "performance" else { return logical }
        if let count = readings.performanceCores() { return (count, "performance") }
        if let count = readings.physicalCores(), count > 0 { return (count, "physical") }
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

    /// The share of RAM available (macOS kern.memorystatus_level, the "System-wide
    /// memory free percentage" memory_pressure prints; Linux MemAvailable / MemTotal),
    /// nil when unreadable.
    public func availableRAMFraction() -> Double? {
        readings.availableRAMFraction()
    }

    /// This host's name from the kernel (never a blocking name lookup).
    public func hostName() -> String {
        readings.hostName() ?? "localhost"
    }

    /// The memory pressure read with the other numbers (Linux PSI against the
    /// formula's `psiSomeAvg10`); nil on macOS, where the event feed reports it.
    public func memoryPressure(formula: HostBudgetFormula) -> HostMemoryPressure? {
        readings.memoryPressure(psiThreshold: formula.psiSomeAvg10)
    }

    public func load1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        // SAFETY: getloadavg writes at most 3 values into the array's own storage, lent for the call.
        return unsafe getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// Bytes swapped out since boot (vm_stat's Swapouts on macOS, `pswpout` on Linux, in bytes).
    public func swappedOutBytes() -> UInt64? {
        readings.swappedOutBytes()
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
