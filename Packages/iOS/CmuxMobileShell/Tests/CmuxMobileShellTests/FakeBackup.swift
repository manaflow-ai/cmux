@testable import CmuxMobileShell

/// In-memory backup double: records uploaded ops, counts fetches, and can be
/// told to fail the first N fetches to exercise the retry path.
actor FakeBackup: PairedMacBackingUp {
    private(set) var uploaded: [PairedMacBackupOp] = []
    private(set) var uploadedTeamIDs: [String?] = []
    private(set) var fetchCount = 0
    private let records: [PairedMacBackupRecord]
    private var failNextFetches: Int

    init(records: [PairedMacBackupRecord] = [], failNextFetches: Int = 0) {
        self.records = records
        self.failNextFetches = failNextFetches
    }

    func upload(ops: [PairedMacBackupOp]) async {
        uploaded.append(contentsOf: ops)
        uploadedTeamIDs.append(nil)
    }

    func upload(ops: [PairedMacBackupOp], teamID: String?) async {
        uploaded.append(contentsOf: ops)
        uploadedTeamIDs.append(teamID)
    }

    func fetchAll() async -> [PairedMacBackupRecord]? {
        fetchCount += 1
        if failNextFetches > 0 {
            failNextFetches -= 1
            return nil
        }
        return records
    }

    func uploadedOps() -> [PairedMacBackupOp] { uploaded }
    func uploadTeams() -> [String?] { uploadedTeamIDs }
    func fetches() -> Int { fetchCount }
}
