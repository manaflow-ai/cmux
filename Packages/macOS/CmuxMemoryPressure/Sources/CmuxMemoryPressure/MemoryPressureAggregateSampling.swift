public import Foundation

/// Supplies a timestamped aggregate process-memory sample.
public protocol MemoryPressureAggregateSampling: Sendable {
    /// Captures aggregate memory at the supplied timestamp.
    func sample(at sampledAt: Date) async -> MemoryPressureAggregateSample
}

/// Supplies the process-tree data needed by the aggregate sampler.
public protocol MemoryPressureAggregateProcessSnapshot: Sendable {
    /// Whether the process census contains every record it attempted to enumerate.
    var enumerationIsComplete: Bool { get }
    /// The provider's count of records omitted during enumeration.
    var enumerationMissingProcessCount: Int { get }

    /// Returns the captured root-and-descendant PID set.
    func aggregateExpandedPIDs(rootPIDs: Set<Int>) -> Set<Int>
    /// Returns a captured process record without querying the live process table.
    func aggregateProcess(pid: Int) -> MemoryPressureAggregateProcessRecord?
}

/// Coalition usage returned by the optional macOS coalition ABI.
public struct MemoryPressureCoalitionUsage: Equatable, Sendable {
    /// The coalition's instantaneous physical footprint in bytes.
    public let physicalFootprintBytes: UInt64

    /// Creates a coalition usage value.
    public init(physicalFootprintBytes: UInt64) {
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

/// Reads coalition accounting when the running OS exports a verified ABI.
public protocol MemoryPressureCoalitionSampling: Sendable {
    /// Returns coalition usage for a process, or `nil` when unavailable.
    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage?
}
