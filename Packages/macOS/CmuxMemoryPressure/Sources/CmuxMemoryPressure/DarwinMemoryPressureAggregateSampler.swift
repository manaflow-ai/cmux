public import CmuxFoundation
public import Darwin
public import Foundation

/// Captures cmux and all unique descendants, preferring the resource coalition.
public struct DarwinMemoryPressureAggregateSampler: MemoryPressureAggregateSampling {
    private let processID: Int
    private let snapshotProvider: @Sendable () async -> any MemoryPressureAggregateProcessSnapshot
    private let coalitionSampler: any MemoryPressureCoalitionSampling
    private let physicalMemoryProvider: @Sendable () -> UInt64
    private let availableMemoryProvider: @Sendable () -> UInt64?

    /// Creates a sampler with injected process and system-memory providers.
    public init(
        processID: Int = Int(getpid()),
        snapshotProvider: @escaping @Sendable () async -> any MemoryPressureAggregateProcessSnapshot,
        coalitionSampler: any MemoryPressureCoalitionSampling = DarwinMemoryPressureCoalitionSampler(),
        physicalMemoryProvider: @escaping @Sendable () -> UInt64 = {
            ProcessInfo.processInfo.physicalMemory
        },
        availableMemoryProvider: @escaping @Sendable () -> UInt64? = {
            DarwinSystemMemorySnapshot()?.availableBytes
        }
    ) {
        self.processID = processID
        self.snapshotProvider = snapshotProvider
        self.coalitionSampler = coalitionSampler
        self.physicalMemoryProvider = physicalMemoryProvider
        self.availableMemoryProvider = availableMemoryProvider
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    /// Captures coalition or process-tree bytes while preserving coverage metadata.
    public func sample(at sampledAt: Date) async -> MemoryPressureAggregateSample {
        let physicalMemoryBytes = physicalMemoryProvider()
        let availableMemoryBytes = availableMemoryProvider()
        if let coalitionUsage = coalitionSampler.usage(forProcessID: processID),
           coalitionUsage.physicalFootprintBytes > 0,
           physicalMemoryBytes > 0,
           coalitionUsage.physicalFootprintBytes <= UInt64(Int64.max) {
            return MemoryPressureAggregateSample(
                source: .coalition,
                aggregateBytes: coalitionUsage.physicalFootprintBytes,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: 0,
                missingProcessCount: 0,
                sampledAt: sampledAt
            )
        }

        let snapshot = await snapshotProvider()
        let descendantPIDs = snapshot.aggregateExpandedPIDs(rootPIDs: [processID])
        var processFootprints: [MemoryPressureAggregateProcessFootprint] = []
        processFootprints.reserveCapacity(descendantPIDs.count)
        var missingProcessCount = snapshot.enumerationMissingProcessCount
        var missingReason: MemoryPressureAggregateMissingReason?
        if !snapshot.enumerationIsComplete {
            missingProcessCount = max(missingProcessCount, 1)
            missingReason = .incompleteEnumeration
        }

        for pid in descendantPIDs {
            guard let process = snapshot.aggregateProcess(pid: pid) else {
                missingProcessCount += 1
                missingReason = missingReason ?? .processExitRace
                continue
            }
            guard process.hasReadableMemory, process.memoryBytes >= 0 else {
                missingProcessCount += 1
                missingReason = missingReason ?? .unreadableProcessRecord
                continue
            }
            processFootprints.append(
                MemoryPressureAggregateProcessFootprint(
                    pid: pid,
                    bytes: UInt64(process.memoryBytes)
                )
            )
        }

        let accounting = MemoryPressureAggregateAccounting().summarize(processFootprints)

        guard !descendantPIDs.isEmpty else {
            return MemoryPressureAggregateSample(
                source: .unavailable,
                aggregateBytes: nil,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: 0,
                missingProcessCount: missingProcessCount,
                missingReason: missingReason,
                sampledAt: sampledAt
            )
        }

        guard !processFootprints.isEmpty else {
            return MemoryPressureAggregateSample(
                source: .unavailable,
                aggregateBytes: nil,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: descendantPIDs.count,
                missingProcessCount: missingProcessCount,
                missingReason: missingReason,
                sampledAt: sampledAt
            )
        }

        guard snapshot.enumerationIsComplete, missingProcessCount == 0 else {
            return MemoryPressureAggregateSample(
                source: .descendantProcessTree,
                aggregateBytes: accounting.aggregateBytes,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: descendantPIDs.count,
                missingProcessCount: missingProcessCount,
                missingReason: missingReason ?? .processExitRace,
                sampledAt: sampledAt
            )
        }

        return MemoryPressureAggregateSample(
            source: .descendantProcessTree,
            aggregateBytes: accounting.aggregateBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            availableMemoryBytes: availableMemoryBytes,
            processCount: accounting.uniquePIDs.count,
            missingProcessCount: 0,
            sampledAt: sampledAt
        )
    }
}
