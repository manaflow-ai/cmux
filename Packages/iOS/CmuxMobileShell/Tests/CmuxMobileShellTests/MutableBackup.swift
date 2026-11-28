@testable import CmuxMobileShell

/// Backup double whose records can change mid-session, to model a Mac
/// republishing a fresh route after the once-per-launch restore already ran.
actor MutableBackup: PairedMacBackingUp {
    private var records: [PairedMacBackupRecord]
    private(set) var fetchCount = 0

    init(records: [PairedMacBackupRecord]) {
        self.records = records
    }

    func setRecords(_ records: [PairedMacBackupRecord]) { self.records = records }
    func upload(ops: [PairedMacBackupOp]) async -> Bool { true }
    func fetchAll() async -> [PairedMacBackupRecord]? {
        await fetchSnapshot()?.records
    }
    func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        fetchCount += 1
        return PairedMacBackupSnapshot(records: records)
    }
    func fetches() -> Int { fetchCount }
}
