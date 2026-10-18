import Foundation

/// A vault failure that is not a validation error.
public enum CloudSecretVaultError: Error, Equatable, LocalizedError {
    /// The stored document was written by a newer cmux. It is left untouched.
    case unsupportedVersion(Int)
    /// The stored document could not be decoded. It is left untouched.
    case corrupt
    /// ``CloudSecretVault/recordDelivered(machineID:plan:at:)`` got a plan for another machine.
    case planMachineMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(format: String(localized: "cloudSecrets.error.unsupportedVersion", defaultValue: "Cloud Secrets were saved by a newer version of cmux (format %ld). Update cmux to use them."), version)
        case .corrupt:
            return String(localized: "cloudSecrets.error.corrupt", defaultValue: "The Cloud Secrets stored in the Keychain could not be read.")
        case .planMachineMismatch(let expected, let actual):
            return String(format: String(localized: "cloudSecrets.error.planMachineMismatch", defaultValue: "A sync plan for %1$@ was recorded against %2$@."), actual, expected)
        }
    }
}
