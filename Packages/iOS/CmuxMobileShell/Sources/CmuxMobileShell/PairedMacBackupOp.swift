/// A single paired-Mac backup mutation.
public enum PairedMacBackupOp: Sendable, Equatable {
    /// Upsert a complete backup record.
    case upsert(PairedMacBackupRecord)
    /// Upsert host reachability/active state while preserving server-side customizations.
    case upsertPreservingCustomizations(PairedMacBackupRecord)
    /// Upsert a complete backup record as an explicit user re-add after a server tombstone.
    case revive(PairedMacBackupRecord)
    /// Revive a tombstoned record while preserving any live server-side customizations.
    case revivePreservingCustomizations(PairedMacBackupRecord)
    /// Tombstone the record with the given Mac device id.
    case delete(macDeviceID: String)
}
