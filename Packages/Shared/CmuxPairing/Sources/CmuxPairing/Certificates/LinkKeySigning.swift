public import Foundation

/// Signs with the install's Secure Enclave key (ES256 over SHA-256 of the
/// message, raw r||s). `CmuxiOSIdentity.InstallIdentity.signWithInstallKey`
/// conforms in the app; tests use a software key.
public protocol LinkKeySigning: Sendable {
    func sign(_ message: Data) async throws -> Data
}
