public import Foundation

/// Resource usage (CPU, memory, process counts and PIDs) for a single Task
/// Manager row or snapshot total, parsed from the snapshot wire payload.
public struct CmuxTaskManagerResources: Equatable {
    /// An all-zero resources value used as an aggregation seed.
    public static let zero = CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 0)

    /// Percent of a single CPU core, `0` or greater.
    public let cpuPercent: Double
    /// Reported memory footprint in bytes (defaults to `residentBytes`).
    public let memoryBytes: Int64
    /// Resident set size in bytes.
    public let residentBytes: Int64
    /// Number of processes contributing to this row.
    public let processCount: Int
    /// Contributing PIDs in canonical (deduped, ascending) order.
    public let processIds: [Int]

    public init(
        cpuPercent: Double,
        residentBytes: Int64,
        memoryBytes: Int64? = nil,
        processCount: Int,
        processIds: [Int] = []
    ) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes ?? residentBytes
        self.residentBytes = residentBytes
        self.processCount = processCount
        self.processIds = Self.canonicalIds(processIds)
    }

    public init(_ payload: [String: Any]) {
        let reader = TaskManagerJSONPayloadReader(payload)
        self.cpuPercent = reader.double("cpu_percent")
        self.memoryBytes = reader.int64("memory_bytes", fallbackKeys: "resident_bytes")
        self.residentBytes = reader.int64("resident_bytes")
        self.processCount = reader.int("process_count") ?? 0
        self.processIds = Self.canonicalIds(reader.intArray("pids"))
    }

    /// Canonical (deduped + ascending) ordering so synthesized
    /// `Equatable` stays stable across snapshot reorderings. See
    /// `CmuxTaskManagerRow.canonicalIds` for the same rationale.
    private static func canonicalIds(_ ids: [Int]) -> [Int] {
        guard !ids.isEmpty else { return ids }
        return Array(Set(ids)).sorted()
    }
}
