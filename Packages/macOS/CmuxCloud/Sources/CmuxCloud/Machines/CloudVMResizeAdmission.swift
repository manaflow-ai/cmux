import Foundation

/// The resource shape requested by a grow-only Cloud VM resize.
public struct CloudVMResizeShape: Equatable, Sendable {
    /// Creates a shape. A nil dimension means that dimension is unchanged.
    public init(vcpus: Int? = nil, memoryMb: Int? = nil, diskMb: Int? = nil) {
        self.vcpus = vcpus
        self.memoryMb = memoryMb
        self.diskMb = diskMb
    }

    public let vcpus: Int?
    public let memoryMb: Int?
    public let diskMb: Int?
}

/// Plan ceilings and the optional shared compute pool used for resize admission.
public struct CloudVMResizeLimits: Equatable, Sendable {
    /// Creates resize limits. Memory and disk are expressed in MB.
    public init(maxVcpus: Int, maxMemoryMb: Int, maxDiskMb: Int, resourcePool: CloudVMResourcePool? = nil) {
        self.maxVcpus = maxVcpus
        self.maxMemoryMb = maxMemoryMb
        self.maxDiskMb = maxDiskMb
        self.resourcePool = resourcePool
    }

    public let maxVcpus: Int
    public let maxMemoryMb: Int
    public let maxDiskMb: Int
    public let resourcePool: CloudVMResourcePool?
}

/// The reason a resize target is unavailable to the caller.
public enum CloudVMResizeAdmissionFailure: Equatable, Sendable {
    /// The target is over a per-machine plan ceiling.
    case planLimit(resource: Resource, requested: Int, maximum: Int)
    /// The target is not larger than the current reservation.
    case notLarger(resource: Resource, requested: Int, current: Int)
    /// The pool exists, but the current compute shape is unavailable.
    case missingCurrentShape
    /// The target does not fit after the current machine's reservation is removed.
    case poolLimit(requestedVcpus: Int, requestedMemoryMb: Int, freeVcpus: Int, freeMemoryMb: Int)

    /// A user-visible resize dimension.
    public enum Resource: String, Equatable, Sendable {
        case disk
        case vcpus
        case memory
    }
}

/// Shared, pure admission policy for Cloud VM resize surfaces.
public enum CloudVMResizeAdmission {
    /// Evaluates plan ceilings, grow-only semantics, and shared compute capacity.
    ///
    /// - Parameters:
    ///   - target: Dimensions supplied by the caller; nil dimensions are unchanged.
    ///   - current: The server reservation or the best available current shape.
    ///   - usesResourcePool: Whether the machine currently contributes to `used*`.
    ///   - limits: The caller's per-machine ceilings and optional shared pool.
    /// - Returns: `nil` when the target can be submitted, or a typed failure.
    public static func failure(
        target: CloudVMResizeShape,
        current: CloudVMResizeShape?,
        usesResourcePool: Bool,
        limits: CloudVMResizeLimits
    ) -> CloudVMResizeAdmissionFailure? {
        if let requested = target.vcpus {
            if requested > limits.maxVcpus {
                return .planLimit(resource: .vcpus, requested: requested, maximum: limits.maxVcpus)
            }
            if let current = current?.vcpus, requested <= current {
                return .notLarger(resource: .vcpus, requested: requested, current: current)
            }
        }
        if let requested = target.memoryMb {
            if requested > limits.maxMemoryMb {
                return .planLimit(resource: .memory, requested: requested, maximum: limits.maxMemoryMb)
            }
            if let current = current?.memoryMb, requested <= current {
                return .notLarger(resource: .memory, requested: requested, current: current)
            }
        }
        if let requested = target.diskMb {
            if requested > limits.maxDiskMb {
                return .planLimit(resource: .disk, requested: requested, maximum: limits.maxDiskMb)
            }
            if let current = current?.diskMb, requested <= current {
                return .notLarger(resource: .disk, requested: requested, current: current)
            }
        }

        guard let pool = limits.resourcePool else { return nil }
        // A running disk-only resize does not wake or grow compute. A paused
        // machine must fit as a fresh allocation because resize wakes it.
        if usesResourcePool, target.vcpus == nil, target.memoryMb == nil { return nil }
        guard let currentVcpus = current?.vcpus, let currentMemoryMb = current?.memoryMb else {
            return .missingCurrentShape
        }
        let targetVcpus = target.vcpus ?? currentVcpus
        let targetMemoryMb = target.memoryMb ?? currentMemoryMb
        let otherVcpus = usesResourcePool ? max(0, pool.usedVcpus - currentVcpus) : pool.usedVcpus
        let otherMemoryMb = usesResourcePool ? max(0, pool.usedMemoryMb - currentMemoryMb) : pool.usedMemoryMb
        let freeVcpus = max(0, pool.poolVcpus - otherVcpus)
        let freeMemoryMb = max(0, pool.poolMemoryMb - otherMemoryMb)
        guard targetVcpus <= freeVcpus, targetMemoryMb <= freeMemoryMb else {
            return .poolLimit(
                requestedVcpus: targetVcpus,
                requestedMemoryMb: targetMemoryMb,
                freeVcpus: freeVcpus,
                freeMemoryMb: freeMemoryMb
            )
        }
        return nil
    }
}
