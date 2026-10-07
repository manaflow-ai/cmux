import Foundation

/// The paired device key that signs `hello.auth` (b5-mac-host.md section 3).
/// iOS backs it with a Secure Enclave P-256 key; tests use a software key.
public protocol MobileDeviceSigner: Sendable {
    /// The install id the key was paired as (`in_…`).
    var install: String { get }
    /// The key id the trust store holds for this install.
    var keyID: String { get }
    /// Raw r||s ECDSA P-256 signature of `message`.
    func sign(_ message: Data) throws -> Data
}
