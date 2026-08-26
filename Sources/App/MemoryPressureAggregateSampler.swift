import Darwin
import Foundation

/// Supplies a timestamped aggregate process-memory sample.
protocol MemoryPressureAggregateSampling: Sendable {
    func sample(at sampledAt: Date) -> MemoryPressureAggregateSample
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
    private let snapshotProvider: @Sendable () -> CmuxTopProcessSnapshot
    private let coalitionSampler: any MemoryPressureCoalitionSampling
    private let physicalMemoryProvider: @Sendable () -> UInt64
    private let availableMemoryProvider: @Sendable () -> UInt64?

    init(
        processID: Int = Int(getpid()),
        snapshotProvider: @escaping @Sendable () -> CmuxTopProcessSnapshot = {
            CmuxTopProcessSnapshot.captureCached(
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
            DarwinMemoryPressureAvailableMemory.bytes()
        }
    ) {
        self.processID = processID
        self.snapshotProvider = snapshotProvider
        self.coalitionSampler = coalitionSampler
        self.physicalMemoryProvider = physicalMemoryProvider
        self.availableMemoryProvider = availableMemoryProvider
    }

    func sample(at sampledAt: Date) -> MemoryPressureAggregateSample {
        let snapshot = snapshotProvider()
        let descendantPIDs = snapshot.descendantPIDs(
            rootPID: processID,
            includeRoot: true
        )
        var processFootprints: [MemoryPressureAggregateProcessFootprint] = []
        processFootprints.reserveCapacity(descendantPIDs.count)
        var missingProcessCount = 0

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
        let physicalMemoryBytes = physicalMemoryProvider()
        let availableMemoryBytes = availableMemoryProvider()
        let coalitionUsage = coalitionSampler.usage(forProcessID: processID)

        if let coalitionUsage,
           coalitionUsage.physicalFootprintBytes > 0 {
            return MemoryPressureAggregateSample(
                source: .coalition,
                aggregateBytes: coalitionUsage.physicalFootprintBytes,
                physicalMemoryBytes: physicalMemoryBytes,
                availableMemoryBytes: availableMemoryBytes,
                processCount: descendantPIDs.count,
                missingProcessCount: missingProcessCount,
                sampledAt: sampledAt
            )
        }

        guard !descendantPIDs.isEmpty, missingProcessCount == 0 else {
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
    private static let coalitionInfoFlavor = 20

    func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? {
        guard processID > 0 else { return nil }
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
        let usageResult = withUnsafeMutableBytes(of: &usage) { rawBuffer in
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

/// Conservative available-memory estimate used only as coalition corroboration.
private struct DarwinMemoryPressureAvailableMemory: Sendable {
    static func bytes() -> UInt64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pages = [
            UInt64(statistics.free_count),
            UInt64(statistics.inactive_count),
            UInt64(statistics.speculative_count),
            UInt64(statistics.purgeable_count)
        ].reduce(into: UInt64(0)) { total, pageCount in
            let (sum, overflow) = total.addingReportingOverflow(pageCount)
            total = overflow ? UInt64.max : sum
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? UInt64.max : bytes
    }
}
