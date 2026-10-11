public import Foundation

/// The shape of a Cloud machine. The server maps this to its current image
/// manifest, so the phone never needs to know provider-specific image IDs.
public enum CloudMachineKind: String, CaseIterable, Sendable, Equatable, Hashable {
    /// A shell-only machine that boots quickly and uses fewer resources.
    case base
    /// A machine with the desktop image, when the provider offers one.
    case desktop

    /// The product default used by the Mac New Machine sheet.
    public static let defaultKind: CloudMachineKind = .desktop
}

/// Options accepted by `POST /api/vm` when creating a Cloud machine.
public struct CloudMachineCreateOptions: Sendable, Equatable {
    public var kind: CloudMachineKind
    public var provider: String?
    public var image: String?
    public var persistentHome: Bool
    public var perMachineHome: Bool
    public var memoryMb: Int?

    public init(
        kind: CloudMachineKind = .base,
        provider: String? = nil,
        image: String? = nil,
        persistentHome: Bool = false,
        perMachineHome: Bool = false,
        memoryMb: Int? = nil
    ) {
        self.kind = kind
        self.provider = provider
        self.image = image
        self.persistentHome = persistentHome
        self.perMachineHome = perMachineHome
        self.memoryMb = memoryMb
    }
}

/// One Cloud VM as listed by `GET /api/vm`.
///
/// Only the fields the phone shows are decoded; the id doubles as the address
/// the control plane resolves on attach.
public struct CloudMachine: Sendable, Equatable, Identifiable, Hashable {
    /// The control plane's machine id.
    public var id: String
    /// The provider that hosts the machine (`freestyle`, ...).
    public var provider: String
    /// The provider-reported lifecycle status (`running`, `stopped`, ...).
    public var status: String
    /// The user-chosen label, when one is set.
    public var displayName: String?
    /// The control plane's generated name (`whimsical-cobalt-butterfly`),
    /// which the CLI and web app show when there is no label.
    public var slug: String?
    /// The vCPUs and memory this machine draws from the plan's shared pool
    /// while it is active; nil from a control plane that predates the field.
    public var resources: CloudMachineResources?

    /// Creates a machine row.
    /// - Parameters:
    ///   - id: The control plane's machine id.
    ///   - provider: The hosting provider.
    ///   - status: The provider-reported status; `"unknown"` when absent.
    ///   - displayName: The user-chosen label, or nil.
    ///   - slug: The generated name, or nil.
    ///   - resources: The machine's vCPUs and memory, or nil.
    public init(
        id: String,
        provider: String,
        status: String,
        displayName: String? = nil,
        slug: String? = nil,
        resources: CloudMachineResources? = nil
    ) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
        self.resources = resources
    }

    /// The name to show everywhere a machine appears: the label, else the
    /// generated name, else the id shortened to its first eight characters
    /// after the `vm-` prefix the control plane's ids share.
    public var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let slug, !slug.isEmpty { return slug }
        guard id.hasPrefix("vm-"), id.count > 11 else { return id }
        return String(id.prefix(11))
    }

    /// Whether the provider reports the machine as running, which is the only
    /// state where attaching can succeed.
    public var isRunning: Bool { lifecycle == .running }

    /// The control plane's lifecycle state, from the `vm_status` enum.
    public var lifecycle: CloudMachineLifecycle { CloudMachineLifecycle(status: status) }
}

/// One machine's share of the plan's resource pool (`GET /api/vm` `resources`).
public struct CloudMachineResources: Sendable, Equatable, Hashable {
    /// The machine's vCPUs.
    public var vcpus: Int
    /// The machine's memory, in MB.
    public var memoryMb: Int

    /// Creates a machine shape.
    /// - Parameters:
    ///   - vcpus: The machine's vCPUs.
    ///   - memoryMb: The machine's memory, in MB.
    public init(vcpus: Int, memoryMb: Int) {
        self.vcpus = vcpus
        self.memoryMb = memoryMb
    }
}

/// The vCPU and memory pool a plan's active machines share
/// (`GET /api/vm` `limits.poolVcpus`, `poolMemoryMb`, `usedVcpus`,
/// `usedMemoryMb`). Provisioning and running machines draw from it; paused
/// machines do not. The server enforces the pool.
public struct CloudResourcePool: Sendable, Equatable {
    /// vCPUs the plan shares across its machines.
    public var poolVcpus: Int
    /// Memory the plan shares across its machines, in MB.
    public var poolMemoryMb: Int
    /// vCPUs held by provisioning and running machines.
    public var usedVcpus: Int
    /// Memory held by provisioning and running machines, in MB.
    public var usedMemoryMb: Int

    /// Creates a pool readout.
    /// - Parameters:
    ///   - poolVcpus: vCPUs the plan shares.
    ///   - poolMemoryMb: Memory the plan shares, in MB.
    ///   - usedVcpus: vCPUs in use.
    ///   - usedMemoryMb: Memory in use, in MB.
    public init(poolVcpus: Int, poolMemoryMb: Int, usedVcpus: Int, usedMemoryMb: Int) {
        self.poolVcpus = poolVcpus
        self.poolMemoryMb = poolMemoryMb
        self.usedVcpus = usedVcpus
        self.usedMemoryMb = usedMemoryMb
    }

    /// vCPUs a new or resumed machine can still take.
    public var freeVcpus: Int { max(0, poolVcpus - usedVcpus) }
    /// Memory a new or resumed machine can still take, in MB.
    public var freeMemoryMb: Int { max(0, poolMemoryMb - usedMemoryMb) }

    /// Whether a machine of this shape fits what is free right now.
    /// - Parameters:
    ///   - vcpus: The machine's vCPUs.
    ///   - memoryMb: The machine's memory, in MB.
    /// - Returns: True when both dimensions fit.
    public func fits(vcpus: Int, memoryMb: Int) -> Bool {
        vcpus <= freeVcpus && memoryMb <= freeMemoryMb
    }
}

/// Server-authoritative machine limits returned beside the Cloud machine list.
///
/// The Mac New Machine sheet uses the same fields. Keeping them in the shared
/// Cloud model lets mobile show the same size and plan state without guessing
/// from the machine rows.
public struct CloudMachineLimits: Sendable, Equatable {
    public var maxActiveMachines: Int?
    public var activeMachineCount: Int?
    public var planID: String?
    public var memoryOptionsMb: [Int]
    public var lockedMemoryOptionsMb: [Int]?
    public var memoryUpgradePlanID: String?
    public var memoryUpgradePlansByMb: [String: String]?
    /// The shared vCPU and memory pool; nil for plans without one (Go, free)
    /// and control planes that predate it.
    public var resourcePool: CloudResourcePool?

    public init(
        maxActiveMachines: Int? = nil,
        activeMachineCount: Int? = nil,
        planID: String? = nil,
        memoryOptionsMb: [Int] = [],
        lockedMemoryOptionsMb: [Int]? = nil,
        memoryUpgradePlanID: String? = nil,
        memoryUpgradePlansByMb: [String: String]? = nil,
        resourcePool: CloudResourcePool? = nil
    ) {
        self.maxActiveMachines = maxActiveMachines
        self.activeMachineCount = activeMachineCount
        self.planID = planID
        self.memoryOptionsMb = memoryOptionsMb
        self.lockedMemoryOptionsMb = lockedMemoryOptionsMb
        self.memoryUpgradePlanID = memoryUpgradePlanID
        self.memoryUpgradePlansByMb = memoryUpgradePlansByMb
        self.resourcePool = resourcePool
    }
}

/// A machine's lifecycle, mirroring the control plane's `vm_status` enum
/// (`provisioning`, `running`, `failed`, `paused`, `destroyed`).
///
/// A value the phone does not know yet decodes to ``unknown`` rather than
/// failing, so a newer server state never hides the machine.
public enum CloudMachineLifecycle: Sendable, Equatable {
    case provisioning
    case running
    case paused
    case failed
    case destroyed
    case unknown

    public init(status: String) {
        switch status.lowercased() {
        case "provisioning": self = .provisioning
        case "running": self = .running
        case "paused": self = .paused
        case "failed": self = .failed
        case "destroyed": self = .destroyed
        default: self = .unknown
        }
    }

    /// Pausing stops compute and billing while keeping the disk.
    public var canPause: Bool { self == .running }
    /// Resuming brings a paused machine's compute back.
    public var canResume: Bool { self == .paused }
    /// Deleting is offered for every state that still has a machine behind it.
    public var canDelete: Bool {
        switch self {
        case .provisioning, .running, .paused, .failed:
            true
        case .destroyed, .unknown:
            false
        }
    }
}
