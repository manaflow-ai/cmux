/// A complete paired-Mac restore snapshot from the presence backup service.
///
/// `records` contains live saved Macs. `deletedMacDeviceIDs` contains retained
/// delete tombstones that should remove matching local rows before live records
/// are merged.
public struct PairedMacBackupSnapshot: Sendable, Equatable {
    /// Live paired-Mac records, newest-first by the server's restore ordering.
    public var records: [PairedMacBackupRecord]

    /// Mac device IDs with retained delete tombstones in this restore scope.
    public var deletedMacDeviceIDs: [String]

    /// Create a restore snapshot from live records and retained delete IDs.
    public init(
        records: [PairedMacBackupRecord],
        deletedMacDeviceIDs: [String] = []
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
    }
}
