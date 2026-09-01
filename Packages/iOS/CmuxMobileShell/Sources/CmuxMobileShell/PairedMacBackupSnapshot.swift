/// A complete paired-Mac restore snapshot from the presence backup service.
///
/// `records` contains live saved Macs. `deletedMacDeviceIDs` retains the legacy
/// wire name but values are pairing identities (`macDeviceID` plus optional
/// instance tag). Current clients ignore those legacy server tombstones.
public struct PairedMacBackupSnapshot: Sendable, Equatable {
    /// Live paired-Mac records, newest-first by the server's restore ordering.
    public var records: [PairedMacBackupRecord]

    /// Legacy server tombstones retained only for wire compatibility.
    public var deletedMacDeviceIDs: [String]

    /// The server-verified team this snapshot's collection was read from
    /// (echoed by the presence worker), or `nil` when the worker predates the
    /// echo. Every record in the snapshot lives in THAT team's backup, so a
    /// restored record's later delete tombstone must route there.
    public var resolvedTeamID: String?

    /// Whether legacy-scope reconciliation must be retried before this restore
    /// can be memoized as complete. Current-scope records remain valid and may
    /// be restored while this is true.
    public var requiresMigrationRetry: Bool

    /// Create a restore snapshot from live records and compatibility tombstones.
    public init(
        records: [PairedMacBackupRecord],
        deletedMacDeviceIDs: [String] = [],
        requiresMigrationRetry: Bool = false,
        resolvedTeamID: String? = nil
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.requiresMigrationRetry = requiresMigrationRetry
        self.resolvedTeamID = resolvedTeamID
    }

    func requiringMigrationRetry() -> Self {
        var snapshot = self
        snapshot.requiresMigrationRetry = true
        return snapshot
    }
}
