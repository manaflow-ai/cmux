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

    /// Create a restore snapshot from live records and compatibility tombstones.
    public init(
        records: [PairedMacBackupRecord],
        deletedMacDeviceIDs: [String] = []
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
    }
}
