import Foundation

/// A process record supplied by the app's process-table adapter.
public struct MemoryPressureAggregateProcessRecord: Equatable, Sendable {
    /// The process identifier captured in the same process-table snapshot.
    public let pid: Int
    /// The physical-memory value returned by the process-table provider.
    public let memoryBytes: Int64
    /// Whether the provider returned a usable memory source for this record.
    public let hasReadableMemory: Bool

    /// Creates a process record for aggregate accounting.
    ///
    /// - Parameters:
    ///   - pid: The captured process identifier.
    ///   - memoryBytes: The captured physical-memory value.
    ///   - hasReadableMemory: Whether the value is readable and trustworthy.
    public init(pid: Int, memoryBytes: Int64, hasReadableMemory: Bool) {
        self.pid = pid
        self.memoryBytes = memoryBytes
        self.hasReadableMemory = hasReadableMemory
    }
}

/// A readable process contribution passed to the deduplicating reducer.
public struct MemoryPressureAggregateProcessFootprint: Equatable, Sendable {
    /// The process identifier.
    public let pid: Int
    /// The measured physical-memory value.
    public let bytes: UInt64

    /// Creates one readable process contribution.
    public init(pid: Int, bytes: UInt64) {
        self.pid = pid
        self.bytes = bytes
    }
}

/// The deduplicated result of summing process footprints.
public struct MemoryPressureAggregateAccountingResult: Equatable, Sendable {
    /// The saturating sum of unique process footprints.
    public let aggregateBytes: UInt64
    /// Unique positive PIDs in first-seen order.
    public let uniquePIDs: [Int]
    /// PIDs encountered more than once, in first duplicate order.
    public let duplicatePIDs: [Int]
}

/// Sums process footprints once per PID, even when roots overlap.
public struct MemoryPressureAggregateAccounting: Sendable {
    /// Creates an empty deduplicating reducer.
    public init() {}

    /// Reduces readable process records into a saturating, deduplicated total.
    ///
    /// - Parameter processes: Readable process contributions in encounter order.
    /// - Returns: The total and bounded PID accounting metadata.
    public func summarize(
        _ processes: [MemoryPressureAggregateProcessFootprint]
    ) -> MemoryPressureAggregateAccountingResult {
        var bytesByPID: [Int: UInt64] = [:]
        var uniquePIDs: [Int] = []
        var duplicatePIDs: [Int] = []
        var duplicatePIDSet: Set<Int> = []
        for process in processes where process.pid > 0 {
            guard bytesByPID[process.pid] == nil else {
                if duplicatePIDSet.insert(process.pid).inserted {
                    duplicatePIDs.append(process.pid)
                }
                continue
            }
            bytesByPID[process.pid] = process.bytes
            uniquePIDs.append(process.pid)
        }

        let aggregateBytes = uniquePIDs.reduce(into: UInt64(0)) { total, pid in
            let bytes = bytesByPID[pid] ?? 0
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? UInt64.max : sum
        }
        return MemoryPressureAggregateAccountingResult(
            aggregateBytes: aggregateBytes,
            uniquePIDs: uniquePIDs,
            duplicatePIDs: duplicatePIDs
        )
    }
}
