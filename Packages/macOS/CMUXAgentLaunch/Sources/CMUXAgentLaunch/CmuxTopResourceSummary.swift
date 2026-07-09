import Foundation

/// Aggregated CPU/memory totals over a set of processes, plus the per-source
/// fallback/unavailable pid breakdowns. Renders to the `resources` wire payload.
public struct CmuxTopResourceSummary: Sendable {
    /// Summed CPU percentage.
    public var cpuPercent: Double = 0
    /// Summed chosen-memory bytes.
    public var memoryBytes: Int64 = 0
    /// Summed resident bytes.
    public var residentBytes: Int64 = 0
    /// Summed virtual bytes.
    public var virtualBytes: Int64 = 0
    /// Number of processes counted.
    public var processCount: Int = 0
    /// The pids included in the summary.
    public var pids: [Int] = []
    /// Requested root pids that were not present in the snapshot.
    public var missingPIDs: [Int] = []
    /// Pids whose chosen memory came from the resident-size fallback source.
    public var memorySourceFallbackPIDs: [Int] = []
    /// Pids whose resident memory came from the rusage fallback source.
    public var residentMemorySourceFallbackPIDs: [Int] = []
    /// Pids with no available chosen-memory source.
    public var unavailableMemoryPIDs: [Int] = []
    /// Pids with no available resident-memory source.
    public var unavailableResidentMemoryPIDs: [Int] = []

    /// Creates a resource summary. All fields default to empty/zero so callers can
    /// supply any labeled subset (mirroring the former implicit memberwise init).
    public init(
        cpuPercent: Double = 0,
        memoryBytes: Int64 = 0,
        residentBytes: Int64 = 0,
        virtualBytes: Int64 = 0,
        processCount: Int = 0,
        pids: [Int] = [],
        missingPIDs: [Int] = [],
        memorySourceFallbackPIDs: [Int] = [],
        residentMemorySourceFallbackPIDs: [Int] = [],
        unavailableMemoryPIDs: [Int] = [],
        unavailableResidentMemoryPIDs: [Int] = []
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
        self.processCount = processCount
        self.pids = pids
        self.missingPIDs = missingPIDs
        self.memorySourceFallbackPIDs = memorySourceFallbackPIDs
        self.residentMemorySourceFallbackPIDs = residentMemorySourceFallbackPIDs
        self.unavailableMemoryPIDs = unavailableMemoryPIDs
        self.unavailableResidentMemoryPIDs = unavailableResidentMemoryPIDs
    }

    /// The `resources` wire payload for this summary.
    public func payload() -> [String: Any] {
        [
            "cpu_percent": cpuPercent,
            "memory_bytes": memoryBytes,
            "resident_bytes": residentBytes,
            "virtual_bytes": virtualBytes,
            "process_count": processCount,
            "pids": pids,
            "missing_pids": missingPIDs,
            "memory_source_fallback_pids": memorySourceFallbackPIDs,
            "memory_source_fallback_count": memorySourceFallbackPIDs.count,
            "resident_memory_source_fallback_pids": residentMemorySourceFallbackPIDs,
            "resident_memory_source_fallback_count": residentMemorySourceFallbackPIDs.count,
            "unavailable_memory_pids": unavailableMemoryPIDs,
            "unavailable_memory_count": unavailableMemoryPIDs.count,
            "unavailable_resident_memory_pids": unavailableResidentMemoryPIDs,
            "unavailable_resident_memory_count": unavailableResidentMemoryPIDs.count
        ]
    }

    /// The wire payload with CPU/memory totals divided across `occurrenceCount`
    /// occurrences (used when one process is shared by multiple webviews).
    public func attributedPayload(sharedAcross occurrenceCount: Int) -> [String: Any] {
        guard occurrenceCount > 1 else { return payload() }
        var attributed = self
        attributed.cpuPercent /= Double(occurrenceCount)
        attributed.memoryBytes = attributed.memoryBytes / Int64(occurrenceCount)
        attributed.residentBytes = attributed.residentBytes / Int64(occurrenceCount)
        attributed.virtualBytes = attributed.virtualBytes / Int64(occurrenceCount)
        return attributed.payload()
    }
}
