public import Darwin
public import Foundation

/// Reads the private coalition-resource footprint when its ABI is verified.
public struct DarwinMemoryPressureCoalitionSampler: MemoryPressureCoalitionSampling {
    private static let coalitionInfoFlavor: Int32 = 20

    /// Creates a coalition sampler that fails closed when the ABI is unavailable.
    public init() {}

    /// Returns whether the OS is allowlisted with an independently verified buffer layout.
    ///
    /// macOS 27 remains disabled until a macOS 27 host validates the kernel buffer
    /// independently of this compiled Swift layout.
    public nonisolated static func coalitionABIIsSupported(
        operatingSystemMajorVersion: Int =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        [14, 15, 26].contains(operatingSystemMajorVersion) &&
            MemoryLayout<CoalitionResourceUsagePrefix>.size == 328 &&
            MemoryLayout<CoalitionResourceUsagePrefix>.offset(of: \.physicalFootprint) == 320
    }

    /// Reads coalition usage for a process, returning nil on any ABI or kernel mismatch.
    public func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? {
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
              ) else { return nil }

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

    /// Prefix of `struct coalition_resource_usage` through `phys_footprint`.
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
