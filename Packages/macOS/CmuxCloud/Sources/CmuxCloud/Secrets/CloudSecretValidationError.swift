import Foundation

/// Why a secret was refused. Payloads are names only, never values.
public enum CloudSecretValidationError: Error, Equatable, LocalizedError {
    /// The name does not match `^[A-Za-z_][A-Za-z0-9_]{0,127}$`. The payload is never
    /// shown: text in the name position can be a pasted value.
    case invalidName(String)
    /// The name belongs to the machine's shell or to cmux.
    case reservedName(String)
    /// The value contains a newline.
    case multilineValue(String)
    case emptyValue(String)
    /// The value is over ``CloudSecretInput/maxValueBytes``.
    case valueTooLarge(String)
    /// Saving would leave more than ``CloudSecretVault/maxSecrets`` secrets.
    case tooMany
    /// Saving would leave more than ``CloudSecretVault/maxTotalBytes`` of names and
    /// values in the vault.
    case vaultTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return String(localized: "cloudSecrets.error.invalidNameHidden", defaultValue: "A name is not a valid variable name. Use letters, digits and underscores, not starting with a digit.")
        case .reservedName(let name):
            return String(format: String(localized: "cloudSecrets.error.reservedName", defaultValue: "%@ is reserved by the machine or by cmux and cannot be stored as a secret."), name)
        case .multilineValue(let name):
            return String(format: String(localized: "cloudSecrets.error.multilineValue", defaultValue: "The value of %@ must be a single line."), name)
        case .emptyValue(let name):
            return String(format: String(localized: "cloudSecrets.error.emptyValue", defaultValue: "The value of %@ is empty."), name)
        case .valueTooLarge(let name):
            return String(format: String(localized: "cloudSecrets.error.valueTooLarge", defaultValue: "The value of %@ is larger than 32 KB."), name)
        case .tooMany:
            return String(localized: "cloudSecrets.error.tooMany", defaultValue: "Cloud Secrets holds at most 500 secrets.")
        case .vaultTooLarge:
            return String(localized: "cloudSecrets.error.vaultTooLarge", defaultValue: "Cloud Secrets holds at most 1 MB of secrets. Remove some before adding more.")
        }
    }
}
