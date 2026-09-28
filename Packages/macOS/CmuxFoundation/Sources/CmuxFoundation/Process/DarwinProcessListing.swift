public import Darwin

/// Immutable process topology plus completeness of the enumeration that produced it.
///
/// ```swift
/// let listing = DarwinProcessEnumerator().capture()
/// if listing.isComplete { /* build an index from listing.processes */ }
/// ```
public struct DarwinProcessListing: Sendable {
    /// Unique readable process records, including public sysctl fallbacks.
    public let processes: [proc_bsdinfo]
    /// Whether enumeration finished without truncation or unreadable topology.
    public let isComplete: Bool
    /// Listed PIDs whose topology could not be read; excludes unknown truncated rows.
    public let missingProcessCount: Int
    /// Whether the PID list itself was whole. Unlike ``isComplete`` it ignores
    /// listed PIDs that exited before their record was read: those no longer run.
    public let pidListIsComplete: Bool

    public init(processes: [proc_bsdinfo], isComplete: Bool, missingProcessCount: Int, pidListIsComplete: Bool? = nil) {
        self.processes = processes
        self.isComplete = isComplete
        self.missingProcessCount = missingProcessCount
        self.pidListIsComplete = pidListIsComplete ?? isComplete
    }
}
