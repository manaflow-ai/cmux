import Foundation

/// Identifies which kernel source supplied a process's memory measurement in a
/// `CmuxTopProcessSnapshot`. The raw values are the exact `proc_*` API + field
/// names and are emitted verbatim into the `system.top` wire payload, so they
/// must not change.
public enum CmuxTopProcessMemorySource: String, Sendable {
    /// `proc_pid_rusage` physical footprint (the preferred memory measurement).
    case physicalFootprint = "proc_pid_rusage.RUSAGE_INFO_V4.ri_phys_footprint"
    /// `proc_pidinfo` task-info resident size.
    case residentSize = "proc_pidinfo.PROC_PIDTASKINFO.pti_resident_size"
    /// `proc_pid_rusage` resident size (resident-memory fallback).
    case rusageResidentSize = "proc_pid_rusage.RUSAGE_INFO_V4.ri_resident_size"
    /// More than one concrete source contributed to an aggregated summary.
    case mixed
    /// No memory source was available for the process.
    case unavailable
}
