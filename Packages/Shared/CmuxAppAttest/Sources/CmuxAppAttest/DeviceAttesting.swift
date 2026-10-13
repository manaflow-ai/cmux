public import Foundation

/// App Attest and DeviceCheck operations of one app on one device.
///
/// ``AppleDeviceAttest`` is the real service; a stand-in conforms for code
/// that must run where no attestation exists (a VM, a test host).
public protocol DeviceAttesting: Sendable {
    /// Whether App Attest works for this process. False in a VM, and on a Mac
    /// for a binary that LaunchServices did not start.
    var isSupported: Bool { get }

    /// Makes a new App Attest key and returns its key id.
    /// - Throws: ``DeviceAttestError``.
    func generateKey() async throws -> String

    /// Attests the key `keyID` over `clientDataHash` (32 bytes).
    /// - Throws: ``DeviceAttestError``; ``DeviceAttestError/invalidKey`` for a
    ///   key that was attested before in an earlier launch, or that is gone.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data

    /// An assertion by the key `keyID` over `clientDataHash` (32 bytes).
    /// - Throws: ``DeviceAttestError``.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data

    /// A DeviceCheck token for this device.
    /// - Throws: ``DeviceAttestError``.
    func deviceCheckToken() async throws -> Data
}

/// Why an App Attest or DeviceCheck call failed, without the system message.
public enum DeviceAttestError: Error, Sendable, Equatable {
    /// The service does not work for this process.
    case unsupported
    /// The key is unknown, or cannot be attested again.
    case invalidKey
    /// Any other failure (a server, input or system error).
    case failed
}
