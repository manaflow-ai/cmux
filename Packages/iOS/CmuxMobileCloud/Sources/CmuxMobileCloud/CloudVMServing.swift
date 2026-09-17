public import Foundation

/// The control-plane calls the Cloud section needs.
///
/// ``CloudVMService`` is the production conformer; tests inject a fake.
public protocol CloudVMServing: Sendable {
    /// The account's machines.
    func listMachines() async throws -> [CloudMachine]
    /// Enroll this device's WireGuard peer. Idempotent per fingerprint.
    func enrollTunnel(clientPublicKey: String, deviceFingerprint: String, deviceName: String?) async throws
        -> CloudTunnelEnrollment
    /// Open a `cmux-remote` attach for `machineID`.
    func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint
    /// Approve a first-contact invitation. Returns whether the daemon has
    /// granted it yet; callers poll until true.
    func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool
}
