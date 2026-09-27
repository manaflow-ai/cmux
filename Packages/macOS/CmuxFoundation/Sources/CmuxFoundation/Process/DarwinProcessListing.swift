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
}
