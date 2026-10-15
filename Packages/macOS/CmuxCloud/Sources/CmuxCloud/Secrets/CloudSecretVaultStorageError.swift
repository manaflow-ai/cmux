import Foundation

/// A storage backend failure. Carries a status code only, never stored bytes.
public enum CloudSecretVaultStorageError: Error, Equatable, LocalizedError {
    /// A Keychain call returned this `OSStatus`.
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return String(format: String(localized: "cloudSecrets.error.keychain", defaultValue: "The Keychain could not be read or written (status %d)."), status)
        }
    }
}
