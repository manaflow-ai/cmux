public import Foundation

/// The control-plane calls the Cloud section needs.
///
/// ``CloudVMService`` is the production conformer; tests inject a fake.
public protocol CloudVMServing: Sendable {
    /// The account's machines.
    func listMachines() async throws -> [CloudMachine]
    /// Machines plus the server's current image-kind capability list.
    /// Older test and preview services get a compatibility default.
    func listMachineCatalog() async throws -> CloudMachineCatalog
    /// Create a machine through the existing `/api/vm` control-plane endpoint.
    /// The idempotency key makes a retry safe for paid provider creates.
    func createMachine(options: CloudMachineCreateOptions, idempotencyKey: String) async throws -> CloudMachine
    /// Enroll this device's WireGuard peer. Idempotent per fingerprint.
    func enrollTunnel(clientPublicKey: String, deviceFingerprint: String, tunnelPurpose: CloudTunnelPurpose, deviceName: String?) async throws
        -> CloudTunnelEnrollment
    /// Open a `cmux-remote` attach for `machineID`.
    func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint
    /// Approve a first-contact invitation. Returns whether the daemon has
    /// granted it yet; callers poll until true.
    func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool
}

public extension CloudVMServing {
    func listMachineCatalog() async throws -> CloudMachineCatalog {
        CloudMachineCatalog(machines: try await listMachines(), availableKinds: nil)
    }
}

/// The `/api/vm` list and the machine shapes that can be created right now.
public struct CloudMachineCatalog: Sendable, Equatable {
    public var machines: [CloudMachine]
    /// `nil` means an older server did not send capability metadata.
    public var availableKinds: Set<CloudMachineKind>?

    public init(machines: [CloudMachine], availableKinds: Set<CloudMachineKind>? = nil) {
        self.machines = machines
        self.availableKinds = availableKinds
    }
}
