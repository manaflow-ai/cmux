import CmuxFoundation
import Darwin
import Foundation

/// Supplies a timestamped aggregate process-memory sample.
protocol MemoryPressureAggregateSampling: Sendable {
    func sample(at sampledAt: Date) async -> MemoryPressureAggregateSample
}

/// Coalition usage returned by the optional macOS coalition ABI.
struct MemoryPressureCoalitionUsage: Equatable, Sendable {
    let physicalFootprintBytes: UInt64
}

/// Injectable seam for coalition accounting; unavailable platforms return nil.
protocol MemoryPressureCoalitionSampling: Sendable {
    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage?
}

/// Captures cmux plus all unique descendants, preferring the resource coalition.
struct DarwinMemoryPressureAggregateSampler: MemoryPressureAggregateSampling {
    private let processID: Int
    private let snapshotProvider: @Sendable () async -> CmuxTopProcessSnapshot
    private let coalitionSampler: any MemoryPressureCoalitionSampling
    private let physicalMemoryProvider: @Sendable () -> UInt64
    private let availableMemoryProvider: @Sendable () -> UInt64?

    init(
        processID: Int = Int(getpid()),
        snapshotProvider: @escaping @Sendable () async -> CmuxTopProcessSnapshot = {
            await CmuxTopProcessSnapshot.captureCached(
                includeProcessDetails: false,
                includeCMUXScope: false,
                maximumAge: 15
            )
        },
        coalitionSampler: any MemoryPressureCoalitionSampling =
            DarwinMemoryPressureCoalitionSampler(),
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
    func sample(at sampledAt: Date) async -> MemoryPressureAggregateSample {
        let physicalMemoryBytes = physicalMemoryProvider()
        let availableMemoryBytes = availableMemoryProvider()
        if let coalitionUsage = coalitionSampler.usage(forProcessID: processID),
           coalitionUsage.physicalFootprintBytes > 0,
           physicalMemoryBytes > 0,
           coalitionUsage.physicalFootprintBytes <= UInt64(Int64.max) {
            // XNU sums current task phys_footprint ledgers, including compressed
            // memory. Installed RAM is not an upper bound. Falling back here
            // would lose coalition members reparented after their parent exited.
            // Reject only values outside the kernel's signed ledger domain.
            // Coalition accounting already covers cmux and its descendants;
            // avoid a full process-table walk on the normal path. The count is
            // intentionally zero because no descendant enumeration occurred.
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
        let descendantPIDs = snapshot.expandedPIDs(rootPIDs: [processID])
        var processFootprints: [MemoryPressureAggregateProcessFootprint] = []
        processFootprints.reserveCapacity(descendantPIDs.count)
        var missingProcessCount = snapshot.enumerationMissingProcessCount

        for pid in descendantPIDs {
            guard let process = snapshot.process(pid: pid),
                  process.memorySource != .unavailable,
                  process.memoryBytes >= 0 else {
                missingProcessCount += 1
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

        guard snapshot.enumerationIsComplete,
              !descendantPIDs.isEmpty, missingProcessCount == 0 else {
            return MemoryPressureAggregateSample(
                source: .unavailable,
                aggregateBytes: nil,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: descendantPIDs.count,
                missingProcessCount: missingProcessCount,
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

/// Reads the resource-coalition footprint when the running OS exports it.
struct DarwinMemoryPressureCoalitionSampler: MemoryPressureCoalitionSampling {
    private static let coalitionInfoFlavor: Int32 = 20

    /// Returns whether this process is running on an OS whose private
    /// coalition-resource layout is known and matches our compiled prefix.
    /// Unknown OS releases deliberately fall back to descendant accounting.
    nonisolated static func coalitionABIIsSupported(
        operatingSystemMajorVersion: Int =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        [14, 15, 26].contains(operatingSystemMajorVersion) &&
            MemoryLayout<CoalitionResourceUsagePrefix>.size == 328 &&
            MemoryLayout<CoalitionResourceUsagePrefix>.offset(of: \.physicalFootprint) == 320
    }

    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? {
        guard processID > 0, Self.coalitionABIIsSupported() else { return nil }
        var coalitionInfo = CoalitionInfo()
        let result = withUnsafeMutableBytes(of: &coalitionInfo) { rawBuffer in
            proc_pidinfo(
                pid_t(processID),
                Self.coalitionInfoFlavor,
                0,
                rawBuffer.baseAddress,
                Int32(MemoryLayout<CoalitionInfo>.size)
            )
        }
        guard result == MemoryLayout<CoalitionInfo>.size else { return nil }
        let coalitionID = coalitionInfo.resourceCoalitionID
        guard coalitionID > 0,
              let symbol = dlsym(
                  UnsafeMutableRawPointer(bitPattern: -2),
                  "coalition_info_resource_usage"
              ) else {
            return nil
        }

        // This private ABI is deliberately optional. The prefix layout is
        // stable through macOS 15 and the kernel copies only the requested
        // size; a missing/changed symbol simply selects the safe tree fallback.
        typealias CoalitionInfoFunction = @convention(c) (
            UInt64,
            UnsafeMutableRawPointer,
            Int
        ) -> Int32
        let coalitionInfoFunction = unsafeBitCast(symbol, to: CoalitionInfoFunction.self)
        var usage = CoalitionResourceUsagePrefix()
        let usageResult: Int32 = withUnsafeMutableBytes(of: &usage) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return coalitionInfoFunction(
                coalitionID,
                baseAddress,
                MemoryLayout<CoalitionResourceUsagePrefix>.size
            )
        }
        guard usageResult == 0, usage.physicalFootprint > 0 else { return nil }
        return MemoryPressureCoalitionUsage(
            physicalFootprintBytes: usage.physicalFootprint
        )
    }

    private struct CoalitionInfo {
        var resourceCoalitionID: UInt64 = 0
        var jetsamCoalitionID: UInt64 = 0
        var reserved1: UInt64 = 0
        var reserved2: UInt64 = 0
        var reserved3: UInt64 = 0
    }

    /// Prefix of `struct coalition_resource_usage` through phys_footprint.
    private struct CoalitionResourceUsagePrefix {
        var tasksStarted: UInt64 = 0
        var tasksExited: UInt64 = 0
        var timeNonempty: UInt64 = 0
        var cpuTime: UInt64 = 0
        var interruptWakeups: UInt64 = 0
        var platformIdleWakeups: UInt64 = 0
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var gpuTime: UInt64 = 0
        var cpuTimeBilledToMe: UInt64 = 0
        var cpuTimeBilledToOthers: UInt64 = 0
        var energy: UInt64 = 0
        var logicalImmediateWrites: UInt64 = 0
        var logicalDeferredWrites: UInt64 = 0
        var logicalInvalidatedWrites: UInt64 = 0
        var logicalMetadataWrites: UInt64 = 0
        var logicalImmediateWritesExternal: UInt64 = 0
        var logicalDeferredWritesExternal: UInt64 = 0
        var logicalInvalidatedWritesExternal: UInt64 = 0
        var logicalMetadataWritesExternal: UInt64 = 0
        var energyBilledToMe: UInt64 = 0
        var energyBilledToOthers: UInt64 = 0
        var cpuPTime: UInt64 = 0
        var cpuTimeEQOSLength: UInt64 = 0
        var cpuTimeEQOS0: UInt64 = 0
        var cpuTimeEQOS1: UInt64 = 0
        var cpuTimeEQOS2: UInt64 = 0
        var cpuTimeEQOS3: UInt64 = 0
        var cpuTimeEQOS4: UInt64 = 0
        var cpuTimeEQOS5: UInt64 = 0
        var cpuTimeEQOS6: UInt64 = 0
        var cpuInstructions: UInt64 = 0
        var cpuCycles: UInt64 = 0
        var fsMetadataWrites: UInt64 = 0
        var pmWrites: UInt64 = 0
        var cpuPInstructions: UInt64 = 0
        var cpuPCycles: UInt64 = 0
        var conclaveMemory: UInt64 = 0
        var aneMachTime: UInt64 = 0
        var aneEnergy: UInt64 = 0
        var physicalFootprint: UInt64 = 0
    }
}
