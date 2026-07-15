@testable import CmuxMobileShell

/// In-memory backup double: records uploaded ops, counts fetches, and can be
/// told to fail the first N fetches to exercise the retry path.
actor FakeBackup: PairedMacBackingUp {
    private(set) var uploaded: [PairedMacBackupOp] = []
    private(set) var uploadedTeamIDs: [String?] = []
    private(set) var uploadedExpectedUserIDs: [String?] = []
    private(set) var fetchedExpectedUserIDs: [String?] = []
    private(set) var fetchCount = 0
    private let records: [PairedMacBackupRecord]
    private let deletedMacDeviceIDs: [String]
    private var failNextFetches: Int
    private var failNextUploads: Int

    init(
        records: [PairedMacBackupRecord] = [],
        deletedMacDeviceIDs: [String] = [],
        failNextFetches: Int = 0,
        failNextUploads: Int = 0
    ) {
        self.records = records
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.failNextFetches = failNextFetches
        self.failNextUploads = failNextUploads
    }

    func upload(ops: [PairedMacBackupOp]) async -> Bool {
        uploaded.append(contentsOf: ops)
        uploadedTeamIDs.append(nil)
        uploadedExpectedUserIDs.append(nil)
        if failNextUploads > 0 {
            failNextUploads -= 1
            return false
        }
        return true
    }

    func upload(ops: [PairedMacBackupOp], teamID: String?) async -> Bool {
        await upload(ops: ops, teamID: teamID, expectedUserID: nil)
    }

    func upload(ops: [PairedMacBackupOp], teamID: String?, expectedUserID: String?) async -> Bool {
        uploaded.append(contentsOf: ops)
        uploadedTeamIDs.append(teamID)
        uploadedExpectedUserIDs.append(expectedUserID)
        if failNextUploads > 0 {
            failNextUploads -= 1
            return false
        }
        return true
    }

    func fetchAll() async -> [PairedMacBackupRecord]? {
        await fetchSnapshot()?.records
    }

    func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: nil, expectedUserID: nil)
    }

    func fetchSnapshot(teamID: String?, expectedUserID: String?) async -> PairedMacBackupSnapshot? {
        fetchedExpectedUserIDs.append(expectedUserID)
        fetchCount += 1
        if failNextFetches > 0 {
            failNextFetches -= 1
            return nil
        }
        return PairedMacBackupSnapshot(records: records, deletedMacDeviceIDs: deletedMacDeviceIDs)
    }

    func uploadedOps() -> [PairedMacBackupOp] { uploaded }
    func uploadTeams() -> [String?] { uploadedTeamIDs }
    func uploadExpectedUsers() -> [String?] { uploadedExpectedUserIDs }
    func fetchExpectedUsers() -> [String?] { fetchedExpectedUserIDs }
    func fetches() -> Int { fetchCount }
}
