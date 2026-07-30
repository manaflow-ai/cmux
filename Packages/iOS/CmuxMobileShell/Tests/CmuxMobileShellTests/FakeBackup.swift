@testable import CmuxMobileShell

/// In-memory backup double: records uploaded ops, counts fetches, and can be
/// told to fail the first N fetches to exercise the retry path.
actor FakeBackup: PairedMacBackingUp {
    private(set) var uploaded: [PairedMacBackupOp] = []
    private(set) var uploadedTeamIDs: [String?] = []
    private(set) var uploadedExpectedUserIDs: [String?] = []
    private(set) var fetchedExpectedUserIDs: [String?] = []
    private(set) var fetchCount = 0
    private var records: [PairedMacBackupRecord]
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
        uploadedBatches.append(ops)
        uploadedTeamIDs.append(teamID)
        uploadedExpectedUserIDs.append(expectedUserID)
        if failNextUploads > 0 {
            failNextUploads -= 1
            return false
        }
        // Mirror the server: a SUCCESSFUL delete removes the record from the
        // backup, so later fetches no longer return it. A failed upload (above)
        // leaves the record to model an undelivered tombstone.
        for op in ops {
            switch op {
            case .delete(let macDeviceID):
                records.removeAll { $0.macDeviceID == macDeviceID && $0.instanceTag == nil }
            case .deleteInstance(let macDeviceID, let instanceTag):
                records.removeAll { $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag }
            default:
                break
            }
        }
        return true
    }

    /// Every `upload` invocation's ops, one entry per network request, so a
    /// test can count round-trips (not just total ops).
    private(set) var uploadedBatches: [[PairedMacBackupOp]] = []

    func uploadBatches() -> [[PairedMacBackupOp]] { uploadedBatches }

    /// Arm upload failures after construction (e.g. for the forget that follows
    /// a successful seeding upload).
    func setFailNextUploads(_ count: Int) { failNextUploads = count }

    /// The team the fake "server" reports it stored a successful upload under,
    /// mirroring the presence worker's echo of its verified resolved team. When
    /// unset, a successful upload echoes the requested team back verbatim.
    private var echoedResolvedTeamID: String?

    func setEchoedResolvedTeamID(_ teamID: String?) { echoedResolvedTeamID = teamID }

    func uploadReportingResolvedTeam(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?
    ) async -> PairedMacBackupUploadOutcome {
        let succeeded = await upload(ops: ops, teamID: teamID, expectedUserID: expectedUserID)
        return PairedMacBackupUploadOutcome(
            succeeded: succeeded,
            resolvedTeamID: succeeded ? (echoedResolvedTeamID ?? teamID) : nil
        )
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
        return PairedMacBackupSnapshot(
            records: records,
            deletedMacDeviceIDs: deletedMacDeviceIDs,
            // Mirror the worker's echo of its verified resolved team on the
            // restore read too, matching uploadReportingResolvedTeam.
            resolvedTeamID: echoedResolvedTeamID ?? teamID
        )
    }

    func uploadedOps() -> [PairedMacBackupOp] { uploaded }
    func uploadTeams() -> [String?] { uploadedTeamIDs }
    func uploadExpectedUsers() -> [String?] { uploadedExpectedUserIDs }
    func fetchExpectedUsers() -> [String?] { fetchedExpectedUserIDs }
    func fetches() -> Int { fetchCount }
}
