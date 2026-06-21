/// A single paired-Mac backup mutation.
public enum PairedMacBackupOp: Sendable, Equatable {
    /// Upsert a complete backup record.
    case upsert(PairedMacBackupRecord)
    /// Tombstone the record with the given Mac device id.
    case delete(macDeviceID: String)
}
