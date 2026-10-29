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
    /// Whether the PID list itself failed to capture every process.
    ///
    /// ``isComplete`` is `false` both when the PID list was truncated and when a
    /// listed PID could not be read. The second case usually means the process
    /// exited between listing and reading, since the reader falls back to public
    /// `sysctl` for live processes it may not inspect. Callers that only care
    /// about live processes, such as a port scan that joins PIDs to terminals or
    /// parents, can treat a missing PID as gone and check this property instead.
    /// It is also `true` when the PID list could not be read at all.
    public let isTruncated: Bool

    init(
        processes: [proc_bsdinfo],
        isComplete: Bool,
        missingProcessCount: Int,
        isTruncated: Bool = false
    ) {
        self.processes = processes
        self.isComplete = isComplete
        self.missingProcessCount = missingProcessCount
        self.isTruncated = isTruncated
    }
}
