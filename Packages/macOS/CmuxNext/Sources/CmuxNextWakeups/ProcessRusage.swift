public import Darwin

/// One process's energy and wakeup counters (`proc_pid_rusage`, `RUSAGE_INFO_V6`), cumulative since it
/// started: the one reading `debug.energy`'s `processes` (`ProcessEnergy`) and `idle`
/// (``IdleEnergyMonitor``) share, so both count interrupt wakeups the same way.
///
/// Interrupt wakeups are what Chrome reports as idle wakeups (`ProcessMetrics::GetIdleWakeupsPerSecond`,
/// base/process/process_metrics_apple.mm, reads `ri_interrupt_wkups`); package-idle wakeups are a subset.
public struct ProcessRusage: Sendable, Equatable {
    /// CPU energy since the process started (`ri_energy_nj`).
    public var energyNanojoules: UInt64
    /// `ri_interrupt_wkups`.
    public var interruptWakeups: UInt64
    /// `ri_pkg_idle_wkups`, a subset of the interrupt wakeups.
    public var packageIdleWakeups: UInt64

    public init(energyNanojoules: UInt64, interruptWakeups: UInt64, packageIdleWakeups: UInt64) {
        self.energyNanojoules = energyNanojoules
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
    }

    /// Reads `pid`; nil when the process is gone or not ours. One system call that copies the
    /// kernel's counters: no I/O and no wait on another process.
    public static func sample(_ pid: pid_t) -> ProcessRusage? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        return ProcessRusage(energyNanojoules: info.ri_energy_nj, interruptWakeups: info.ri_interrupt_wkups,
                             packageIdleWakeups: info.ri_pkg_idle_wkups)
    }
}
