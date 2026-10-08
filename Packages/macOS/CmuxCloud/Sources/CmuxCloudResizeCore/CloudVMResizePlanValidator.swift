import CoreFoundation
import Foundation

/// The resource shape requested by a grow-only Cloud VM resize.
public struct CloudVMResizeShape: Equatable, Sendable {
    /// Creates a shape. A nil dimension means that dimension is unchanged.
    public init(vcpus: Int? = nil, memoryMb: Int? = nil, diskMb: Int? = nil) {
        self.vcpus = vcpus
        self.memoryMb = memoryMb
        self.diskMb = diskMb
    }

    /// Requested vCPU count, or `nil` when unchanged.
    public let vcpus: Int?
    /// Requested memory in MB, or `nil` when unchanged.
    public let memoryMb: Int?
    /// Requested disk in MB, or `nil` when unchanged.
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

    /// Maximum vCPUs for one machine.
    public let maxVcpus: Int
    /// Maximum memory in MB for one machine.
    public let maxMemoryMb: Int
    /// Maximum disk in MB for one machine.
    public let maxDiskMb: Int
    /// Shared compute pool, when this plan has one.
    public let resourcePool: CloudVMResourcePool?
}

/// The plan facts needed to validate a Cloud VM resize.
public struct CloudVMResizePlan: Equatable, Sendable {
    /// Creates a plan from its identifier and resize limits.
    public init(id: String, limits: CloudVMResizeLimits) {
        self.id = id
        self.limits = limits
    }

    /// The normalized server plan identifier.
    public let id: String
    /// The per-machine ceilings and optional shared compute pool.
    public let limits: CloudVMResizeLimits
}

/// A malformed or incomplete server response that cannot safely be used for a resize.
public enum CloudVMResizePlanError: Error, Equatable, Sendable {
    /// The server returned only part of the shared-pool capacity readout.
    case incompleteCapacityData
}

/// The reason a resize target is unavailable to the caller.
public enum CloudVMResizeViolation: Equatable, Sendable {
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

/// Shared plan decoding and admission policy for Cloud VM resize surfaces.
public struct CloudVMResizePlanValidator: Sendable {
    /// Creates a stateless resize evaluator.
    public init() {}

    /// Decodes server plan limits, applying conservative fallbacks for older
    /// control-plane responses that omit explicit resize ceilings.
    ///
    /// - Parameter rawLimits: The decoded `vm.list` `limits` object.
    /// - Throws: ``CloudVMResizePlanError/incompleteCapacityData`` when a
    ///   partially populated shared-pool readout cannot be trusted.
    /// - Returns: Normalized plan facts for the caller's subscription.
    public func plan(from rawLimits: [String: Any]) throws -> CloudVMResizePlan {
        let planID = (rawLimits["planId"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "pro"
        let maxMemoryFromLadder = (rawLimits["memoryOptionsMb"] as? [Any])?
            .compactMap(positiveLimit)
            .max()
        let maxMemoryMb = positiveLimit(rawLimits["maxMemoryMb"])
            ?? maxMemoryFromLadder
            ?? (planID == "max" ? 64 * 1_024 : planID == "go" ? 4 * 1_024 : 16 * 1_024)
        let maxVcpus = positiveLimit(rawLimits["maxVcpus"])
            ?? max(1, maxMemoryMb / 2_048)
        let maxDiskMb = positiveLimit(rawLimits["maxDiskMb"]) ?? {
            switch planID {
            case "max": return 256 * 1_024
            case "go": return 16 * 1_024
            default: return 128 * 1_024
            }
        }()
        let resourcePool = try resourcePool(from: rawLimits)
        return CloudVMResizePlan(
            id: planID,
            limits: CloudVMResizeLimits(
                maxVcpus: maxVcpus,
                maxMemoryMb: maxMemoryMb,
                maxDiskMb: maxDiskMb,
                resourcePool: resourcePool
            )
        )
    }

    /// Parses a strictly positive integer from JSON-compatible numeric values.
    /// Invalid, negative, fractional, and oversized values return `nil`.
    public func positiveLimit(_ raw: Any?) -> Int? {
        guard let value = nonNegativeLimit(raw), value > 0 else { return nil }
        return value
    }

    /// Parses a resize target against plan ceilings, grow-only semantics, and
    /// shared compute capacity.
    ///
    /// - Parameters:
    ///   - target: Dimensions supplied by the caller; nil dimensions are unchanged.
    ///   - current: The server reservation or the best available current shape.
    ///   - usesResourcePool: Whether the machine currently contributes to `used*`.
    ///   - limits: The caller's per-machine ceilings and optional shared pool.
    /// - Returns: `nil` when the target can be submitted, or a typed violation.
    public func violation(
        target: CloudVMResizeShape,
        current: CloudVMResizeShape?,
        usesResourcePool: Bool,
        limits: CloudVMResizeLimits
    ) -> CloudVMResizeViolation? {
        var hasGrowth = false
        var unchangedViolation: CloudVMResizeViolation?
        if let requested = target.vcpus {
            if requested > limits.maxVcpus {
                return .planLimit(resource: .vcpus, requested: requested, maximum: limits.maxVcpus)
            }
            if let current = current?.vcpus {
                if requested < current {
                    return .notLarger(resource: .vcpus, requested: requested, current: current)
                } else if requested > current {
                    hasGrowth = true
                } else if unchangedViolation == nil {
                    unchangedViolation = .notLarger(resource: .vcpus, requested: requested, current: current)
                }
            }
        }
        if let requested = target.memoryMb {
            if requested > limits.maxMemoryMb {
                return .planLimit(resource: .memory, requested: requested, maximum: limits.maxMemoryMb)
            }
            if let current = current?.memoryMb {
                if requested < current {
                    return .notLarger(resource: .memory, requested: requested, current: current)
                } else if requested > current {
                    hasGrowth = true
                } else if unchangedViolation == nil {
                    unchangedViolation = .notLarger(resource: .memory, requested: requested, current: current)
                }
            }
        }
        if let requested = target.diskMb {
            if requested > limits.maxDiskMb {
                return .planLimit(resource: .disk, requested: requested, maximum: limits.maxDiskMb)
            }
            if let current = current?.diskMb {
                if requested < current {
                    return .notLarger(resource: .disk, requested: requested, current: current)
                } else if requested > current {
                    hasGrowth = true
                } else if unchangedViolation == nil {
                    unchangedViolation = .notLarger(resource: .disk, requested: requested, current: current)
                }
            }
        }
        if !hasGrowth, let unchangedViolation {
            return unchangedViolation
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

    /// Decodes the shared pool only when all capacity and usage counters are valid.
    private func resourcePool(from limits: [String: Any]) throws -> CloudVMResourcePool? {
        let rawPoolVcpus = limits["poolVcpus"]
        let rawPoolMemoryMb = limits["poolMemoryMb"]
        let hasPoolFields = [rawPoolVcpus, rawPoolMemoryMb].contains { raw in
            guard let raw else { return false }
            return !(raw is NSNull)
        }
        guard hasPoolFields else { return nil }
        guard let poolVcpus = positiveLimit(rawPoolVcpus),
              let poolMemoryMb = positiveLimit(rawPoolMemoryMb),
              let usedVcpus = nonNegativeLimit(limits["usedVcpus"]),
              let usedMemoryMb = nonNegativeLimit(limits["usedMemoryMb"]) else {
            throw CloudVMResizePlanError.incompleteCapacityData
        }
        return CloudVMResourcePool(
            poolVcpus: poolVcpus,
            poolMemoryMb: poolMemoryMb,
            usedVcpus: usedVcpus,
            usedMemoryMb: usedMemoryMb
        )
    }

    /// Converts a JSON-compatible numeric value to a nonnegative integer.
    private func nonNegativeLimit(_ raw: Any?) -> Int? {
        let value: Int?
        if let raw = raw as? NSNumber,
                  CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  raw.doubleValue.isFinite {
            value = Int(exactly: raw.doubleValue)
        } else if let raw = raw as? Int {
            value = raw
        } else if let raw = raw as? Int64 {
            value = Int(exactly: raw)
        } else if let raw = raw as? Double, raw.isFinite {
            value = Int(exactly: raw)
        } else {
            value = nil
        }
        guard let value, value >= 0 else { return nil }
        return value
    }
}

/// Compatibility name for callers that still describe a failed admission.
public typealias CloudVMResizeAdmissionFailure = CloudVMResizeViolation

/// Compatibility facade for the original evaluator name.
public typealias CloudVMResizeAdmission = CloudVMResizePlanValidator
