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

    /// Creates a machine row.
    /// - Parameters:
    ///   - id: The control plane's machine id.
    ///   - provider: The hosting provider.
    ///   - status: The provider-reported status; `"unknown"` when absent.
    ///   - displayName: The user-chosen label, or nil.
    public init(id: String, provider: String, status: String, displayName: String? = nil) {
        self.id = id
        self.provider = provider
        self.status = status
        self.displayName = displayName
    }

    /// The name to show: the label when set, otherwise the id.
    public var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }

    /// Whether the provider reports the machine as running, which is the only
    /// state where attaching can succeed.
    public var isRunning: Bool { status.lowercased() == "running" }
}
