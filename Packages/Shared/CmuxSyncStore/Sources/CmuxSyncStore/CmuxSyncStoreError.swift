/// Errors surfaced by ``CmuxSyncStore`` when SQLite access fails. Mirrors
/// ``MobilePairedMacStoreError`` so the two stores have one error vocabulary.
public enum CmuxSyncStoreError: Error, Equatable, Sendable {
    /// `sqlite3_open_v2` failed with the given result code.
    case openFailed(Int32)
    /// `sqlite3_prepare_v2` failed with the given result code and message.
    case prepareFailed(Int32, String)
    /// A statement step failed with the given result code and message.
    case stepFailed(Int32, String)
    /// The on-disk schema version is newer than this build understands.
    case unknownSchemaVersion(Int)
    /// A value could not be encoded for storage.
    case encodeFailed
}
