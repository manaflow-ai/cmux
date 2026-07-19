/// How an upload may change the server's host-owned route/instance tuple.
public enum PairedMacBackupInstanceAuthorityWriteMode: Sendable, Equatable {
    /// Authenticated foreground pairing may replace the current authority.
    case authoritative
    /// Authenticated route refresh may update only an unclaimed or same-tag row.
    case compareAndSet
    /// Metadata-only writes retain the existing server authority tuple.
    case preserve
}

/// A single paired-Mac backup mutation.
public enum PairedMacBackupOp: Sendable, Equatable {
    /// Upsert a complete backup record.
    case upsert(
        PairedMacBackupRecord,
        instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode = .authoritative
    )
    /// Upsert host reachability/active state while preserving server-side customizations.
    case upsertPreservingCustomizations(
        PairedMacBackupRecord,
        instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode = .authoritative
    )
    /// Upsert a complete backup record as an explicit user re-add after a server tombstone.
    case revive(
        PairedMacBackupRecord,
        instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode = .authoritative
    )
    /// Revive a tombstoned record while preserving any live server-side customizations.
    case revivePreservingCustomizations(
        PairedMacBackupRecord,
        instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode = .authoritative
    )
    /// Tombstone the record with the given Mac device id.
    case delete(macDeviceID: String)
}
