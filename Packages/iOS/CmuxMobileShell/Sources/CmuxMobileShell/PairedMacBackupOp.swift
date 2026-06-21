/// A single paired-Mac backup mutation.
public enum PairedMacBackupOp: Sendable, Equatable {
    /// Upsert a complete backup record.
    case upsert(PairedMacBackupRecord)
    /// Upsert a complete backup record as an explicit user re-add after a server tombstone.
    case revive(PairedMacBackupRecord)
    /// Tombstone the record with the given Mac device id.
    case delete(macDeviceID: String)
}
