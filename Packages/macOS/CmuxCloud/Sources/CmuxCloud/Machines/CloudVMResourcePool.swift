import Foundation

/// The plan's shared Cloud VM resource pool and how much of it active machines
/// use (`GET /api/vm` `limits.poolVcpus`, `poolMemoryMb`, `usedVcpus`,
/// `usedMemoryMb`). Every provisioning and running machine draws from one
/// pool; paused machines do not. The server enforces the pool; this type only
/// lets the client explain it before a create fails.
public struct CloudVMResourcePool: Equatable, Sendable {
    /// Creates a pool readout.
    /// - Parameters:
    ///   - poolVcpus: vCPUs the plan shares across its machines.
    ///   - poolMemoryMb: Memory the plan shares across its machines, in MB.
    ///   - usedVcpus: vCPUs held by provisioning and running machines.
    ///   - usedMemoryMb: Memory held by provisioning and running machines, in MB.
    public init(poolVcpus: Int, poolMemoryMb: Int, usedVcpus: Int, usedMemoryMb: Int) {
        self.poolVcpus = poolVcpus
        self.poolMemoryMb = poolMemoryMb
        self.usedVcpus = usedVcpus
        self.usedMemoryMb = usedMemoryMb
    }

    /// Reads the pool from a `limits` object. Nil when the plan has no pool
    /// (Go, free) or the control plane predates the fields.
    /// - Parameter limits: The decoded `limits` JSON object.
    public init?(limits: [String: Any]) {
        guard let poolVcpus = Self.positiveInt(limits["poolVcpus"]),
              let poolMemoryMb = Self.positiveInt(limits["poolMemoryMb"]) else { return nil }
        self.init(
            poolVcpus: poolVcpus,
            poolMemoryMb: poolMemoryMb,
            usedVcpus: Self.nonNegativeInt(limits["usedVcpus"]) ?? 0,
            usedMemoryMb: Self.nonNegativeInt(limits["usedMemoryMb"]) ?? 0
        )
    }

    /// vCPUs the plan shares across its machines.
    public let poolVcpus: Int
    /// Memory the plan shares across its machines, in MB.
    public let poolMemoryMb: Int
    /// vCPUs held by provisioning and running machines.
    public let usedVcpus: Int
    /// Memory held by provisioning and running machines, in MB.
    public let usedMemoryMb: Int

    /// vCPUs a new or resumed machine can still take.
    public var freeVcpus: Int { max(0, poolVcpus - usedVcpus) }
    /// Memory a new or resumed machine can still take, in MB.
    public var freeMemoryMb: Int { max(0, poolMemoryMb - usedMemoryMb) }

    /// Why a machine of a given shape does not fit the remaining pool.
    public enum Shortfall: Equatable, Sendable {
        /// The machine needs more memory than the pool has free (all in MB).
        case memory(requestedMb: Int, freeMb: Int, poolMb: Int)
        /// The machine needs more vCPUs than the pool has free.
        case vcpus(requested: Int, free: Int, pool: Int)
    }

    /// The first dimension a machine of this shape would overflow, memory
    /// first because that is the number people pick a size by.
    /// - Parameters:
    ///   - vcpus: The machine's vCPUs.
    ///   - memoryMb: The machine's memory, in MB.
    /// - Returns: The overflow, or nil when the machine fits.
    public func shortfall(vcpus: Int, memoryMb: Int) -> Shortfall? {
        if memoryMb > freeMemoryMb {
            return .memory(requestedMb: memoryMb, freeMb: freeMemoryMb, poolMb: poolMemoryMb)
        }
        if vcpus > freeVcpus {
            return .vcpus(requested: vcpus, free: freeVcpus, pool: poolVcpus)
        }
        return nil
    }

    /// "16 of 20 vCPUs · 32 of 40 GB RAM in use".
    public var usageText: String {
        String(
            format: String(
                localized: "cloud.machines.pool.usage",
                defaultValue: "%1$lld of %2$lld vCPUs · %3$lld of %4$lld GB RAM in use"
            ),
            Int64(usedVcpus), Int64(poolVcpus),
            Int64(Self.gigabytes(usedMemoryMb)), Int64(Self.gigabytes(poolMemoryMb))
        )
    }

    /// Whether even the smallest machine (2 vCPU / 4 GB) no longer fits.
    public var isExhausted: Bool {
        shortfall(vcpus: 2, memoryMb: 4096) != nil
    }

    /// Explains a shortfall in the New Machine sheet.
    /// - Parameters:
    ///   - shortfall: The overflow from ``shortfall(vcpus:memoryMb:)``.
    ///   - offersUpgrade: Whether a larger plan (Max) is available to the caller.
    /// - Returns: The localized sentence naming the request and what is free.
    public static func shortfallText(_ shortfall: Shortfall, offersUpgrade: Bool) -> String {
        switch shortfall {
        case .memory(let requestedMb, let freeMb, let poolMb):
            let format = offersUpgrade
                ? String(
                    localized: "cloud.newMachine.pool.doesNotFit",
                    defaultValue: "This size needs %1$lld GB RAM, but only %2$lld GB of your %3$lld GB pool is free. Pause or delete a VM, or upgrade to Max."
                )
                : String(
                    localized: "cloud.newMachine.pool.doesNotFitMax",
                    defaultValue: "This size needs %1$lld GB RAM, but only %2$lld GB of your %3$lld GB pool is free. Pause or delete a VM."
                )
            return String(
                format: format,
                Int64(gigabytes(requestedMb)), Int64(gigabytes(freeMb)), Int64(gigabytes(poolMb))
            )
        case .vcpus(let requested, let free, let pool):
            let format = offersUpgrade
                ? String(
                    localized: "cloud.newMachine.pool.doesNotFitVcpus",
                    defaultValue: "This size needs %1$lld vCPUs, but only %2$lld of your %3$lld vCPUs are free. Pause or delete a VM, or upgrade to Max."
                )
                : String(
                    localized: "cloud.newMachine.pool.doesNotFitVcpusMax",
                    defaultValue: "This size needs %1$lld vCPUs, but only %2$lld of your %3$lld vCPUs are free. Pause or delete a VM."
                )
            return String(format: format, Int64(requested), Int64(free), Int64(pool))
        }
    }

    /// Whole gigabytes, rounded down so free space is never overstated.
    static func gigabytes(_ memoryMb: Int) -> Int { max(0, memoryMb) / 1024 }

    private static func positiveInt(_ raw: Any?) -> Int? {
        guard let value = nonNegativeInt(raw), value > 0 else { return nil }
        return value
    }

    private static func nonNegativeInt(_ raw: Any?) -> Int? {
        let value: Int?
        if let int = raw as? Int { value = int }
        else if let number = raw as? NSNumber, number.doubleValue.isFinite { value = Int(exactly: number.doubleValue) }
        else if let double = raw as? Double, double.isFinite { value = Int(exactly: double) }
        else { value = nil }
        guard let value, value >= 0 else { return nil }
        return value
    }
}
