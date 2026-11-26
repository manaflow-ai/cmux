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
    /// When set, models the server's PER-TEAM Durable Objects: each team id
    /// (`""` for the nil team) has its own record list, fetches read only their
    /// team's bucket, and successful deletes remove from only that bucket. When
    /// unset, one shared list backs every team (the legacy single-bucket mode).
    private var recordsByTeam: [String: [PairedMacBackupRecord]]?
    private let deletedMacDeviceIDs: [String]
    private let requiresMigrationRetry: Bool
    private var failNextFetches: Int
    private var failNextUploads: Int

    init(
        records: [PairedMacBackupRecord] = [],
        deletedMacDeviceIDs: [String] = [],
        requiresMigrationRetry: Bool = false,
        failNextFetches: Int = 0,
        failNextUploads: Int = 0
    ) {
        self.records = records
        self.recordsByTeam = nil
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.requiresMigrationRetry = requiresMigrationRetry
        self.failNextFetches = failNextFetches
        self.failNextUploads = failNextUploads
    }

    init(
        recordsByTeam: [String: [PairedMacBackupRecord]],
        deletedMacDeviceIDs: [String] = [],
        requiresMigrationRetry: Bool = false,
        failNextFetches: Int = 0,
        failNextUploads: Int = 0
    ) {
        self.records = []
        self.recordsByTeam = recordsByTeam
        self.deletedMacDeviceIDs = deletedMacDeviceIDs
        self.requiresMigrationRetry = requiresMigrationRetry
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

    /// One-shot hook fired when an upload carrying a delete op ARRIVES (before
    /// it applies), so a test can interleave a concurrent mutation exactly
    /// inside the uploader's suspension window.
    private var onDeleteUpload: (@Sendable () async -> Void)?

    func setOnDeleteUpload(_ hook: @escaping @Sendable () async -> Void) {
        onDeleteUpload = hook
    }

    func upload(ops: [PairedMacBackupOp], teamID: String?, expectedUserID: String?) async -> Bool {
        let carriesDelete = ops.contains {
            switch $0 {
            case .delete, .deleteInstance: return true
            default: return false
            }
        }
        if carriesDelete, let hook = onDeleteUpload {
            onDeleteUpload = nil
            await hook()
        }
        uploaded.append(contentsOf: ops)
        uploadedBatches.append(ops)
        uploadedTeamIDs.append(teamID)
        uploadedExpectedUserIDs.append(expectedUserID)
        if failNextUploads > 0 {
            failNextUploads -= 1
            return false
        }
        // Mirror the server: a SUCCESSFUL delete removes the record and a
        // successful upsert/revive (re)writes it, so later fetches reflect the
        // op order. A failed upload (above) leaves the backup untouched to
        // model an undelivered request. Record writes apply only in PER-TEAM
        // mode — the legacy single-bucket mode returns its seeded list to
        // every team, so applying uploads there would leak one team's mirror
        // into every other team's restore.
        for op in ops {
            switch op {
            case .delete(let macDeviceID):
                removeRecords(teamID: teamID) { $0.macDeviceID == macDeviceID && $0.instanceTag == nil }
            case .deleteInstance(let macDeviceID, let instanceTag):
                removeRecords(teamID: teamID) { $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag }
            case .upsert(let record, _), .upsertPreservingCustomizations(let record, _),
                 .revive(let record, _), .revivePreservingCustomizations(let record, _):
                guard recordsByTeam != nil else { continue }
                removeRecords(teamID: teamID) {
                    $0.macDeviceID == record.macDeviceID && $0.instanceTag == record.instanceTag
                }
                appendRecord(record, teamID: teamID)
            }
        }
        return true
    }

    private func removeRecords(teamID: String?, where matches: (PairedMacBackupRecord) -> Bool) {
        if recordsByTeam != nil {
            recordsByTeam?[teamID ?? ""]?.removeAll(where: matches)
        } else {
            records.removeAll(where: matches)
        }
    }

    private func appendRecord(_ record: PairedMacBackupRecord, teamID: String?) {
        if recordsByTeam != nil {
            recordsByTeam?[teamID ?? "", default: []].append(record)
        } else {
            records.append(record)
        }
    }

    /// Every `upload` invocation's ops, one entry per network request, so a
    /// test can count round-trips (not just total ops).
    private(set) var uploadedBatches: [[PairedMacBackupOp]] = []

    func uploadBatches() -> [[PairedMacBackupOp]] { uploadedBatches }

    /// Arm upload failures after construction (e.g. for the forget that follows
    /// a successful seeding upload).
    func setFailNextUploads(_ count: Int) { failNextUploads = count }

    /// Arm fetch failures after construction (e.g. the network dropping right
    /// before a forget, so only routed tombstones can deliver).
    func setFailNextFetches(_ count: Int) { failNextFetches = count }

    /// Plant a record server-side after construction (e.g. another device
    /// re-pairing a Mac between two of this phone's restores). Per-team mode
    /// only.
    func seedRecord(_ record: PairedMacBackupRecord, teamID: String?) {
        recordsByTeam?[teamID ?? "", default: []].append(record)
    }

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
        let fetched: [PairedMacBackupRecord]
        if let recordsByTeam {
            fetched = recordsByTeam[teamID ?? ""] ?? []
        } else {
            fetched = records
        }
        return PairedMacBackupSnapshot(
            records: fetched,
            deletedMacDeviceIDs: deletedMacDeviceIDs,
            requiresMigrationRetry: requiresMigrationRetry,
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
