/// Errors surfaced by ``MobilePairedMacStore`` when SQLite access fails.
public enum MobilePairedMacStoreError: Error {
    /// `sqlite3_open_v2` failed with the given result code.
    case openFailed(Int32)
    /// `sqlite3_prepare_v2` failed with the given result code and message.
    case prepareFailed(Int32, String)
    /// A statement step failed with the given result code and message.
    case stepFailed(Int32, String)
    /// The on-disk schema version is newer than this build understands.
    case unknownSchemaVersion(Int)
    /// A value could not be encoded for storage.
    case decodeFailed
}
