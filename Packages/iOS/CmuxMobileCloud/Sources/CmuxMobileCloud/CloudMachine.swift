public import Foundation

/// The shape of a Cloud machine. The server maps this to its current image
/// manifest, so the phone never needs to know provider-specific image IDs.
public enum CloudMachineKind: String, CaseIterable, Sendable, Equatable {
    /// A shell-only machine that boots quickly and uses fewer resources.
    case base
    /// A machine with the desktop image, when the provider offers one.
    case desktop
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

    /// Creates a machine row.
    /// - Parameters:
    ///   - id: The control plane's machine id.
    ///   - provider: The hosting provider.
    ///   - status: The provider-reported status; `"unknown"` when absent.
    ///   - displayName: The user-chosen label, or nil.
    ///   - slug: The generated name, or nil.
    public init(id: String, provider: String, status: String, displayName: String? = nil, slug: String? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
        self.slug = slug
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
    public var canDelete: Bool { self != .destroyed }
}
