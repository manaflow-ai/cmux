/// Local encrypted profile-store failures, without addresses or credentials.
public enum MobileRemoteProfileStoreError: Error, Equatable, Sendable {
    /// The caller locked the store and must unlock before accessing profiles.
    case locked
    /// SQLite rejected an operation; only its numeric result is exposed.
    case database(Int32)
    /// Stored metadata or decrypted data violates the profile contract.
    case corruptRecord
    /// The caller's key epoch does not match the persisted vault.
    case keyEpochMismatch
    /// A schema newer than this implementation must not be overwritten.
    case unsupportedSchema
    /// Record growth exceeds the local store's bound.
    case capacityExceeded
}
