/// The result of a backup upload, carrying the server-verified team scope the
/// ops were actually stored under.
///
/// A nil-team upload lets the SERVER resolve which per-team Durable Object
/// stores the records (selected team, else sole team, else the personal
/// scope), and that resolution is not derivable client-side. The presence
/// worker echoes it back so the client can persist where a record's backup
/// really lives and route its later delete tombstone to the same place.
public struct PairedMacBackupUploadOutcome: Sendable, Equatable {
    /// Whether the upload was accepted.
    public let succeeded: Bool
    /// The server-verified team the ops were stored under; `nil` when unknown
    /// (a failed upload, or a transport that predates the echo).
    public let resolvedTeamID: String?

    public init(succeeded: Bool, resolvedTeamID: String?) {
        self.succeeded = succeeded
        self.resolvedTeamID = resolvedTeamID
    }
}

/// The backup transport seam used by backup mirroring and restore.
public protocol PairedMacBackingUp: Sendable {
    /// Push backup mutations best-effort.
    @discardableResult
    func upload(ops: [PairedMacBackupOp]) async -> Bool

    /// Push backup mutations best-effort for an already-captured team scope.
    @discardableResult
    func upload(ops: [PairedMacBackupOp], teamID: String?) async -> Bool

    /// Push backup mutations only if auth still belongs to the captured account.
    @discardableResult
    func upload(ops: [PairedMacBackupOp], teamID: String?, expectedUserID: String?) async -> Bool

    /// Push backup mutations and report the server-verified team they were
    /// stored under, so the caller can persist a record's real backup scope.
    @discardableResult
    func uploadReportingResolvedTeam(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?
    ) async -> PairedMacBackupUploadOutcome

    /// Fetch the caller's full backed-up list, or `nil` on transport/auth failure.
    func fetchAll() async -> [PairedMacBackupRecord]?

    /// Fetch the caller's full backed-up list for an already-captured team scope.
    func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]?

    /// Fetch live records plus retained delete tombstones, or `nil` on
    /// transport/auth failure.
    func fetchSnapshot() async -> PairedMacBackupSnapshot?

    /// Fetch live records plus retained delete tombstones for an
    /// already-captured team scope.
    func fetchSnapshot(teamID: String?) async -> PairedMacBackupSnapshot?

    /// Fetch live records and tombstones only if auth still belongs to the captured account.
    func fetchSnapshot(teamID: String?, expectedUserID: String?) async -> PairedMacBackupSnapshot?

    /// Optional client-owned restore/upload scope layered below the verified team
    /// and user. Tagged iOS builds use this to keep their saved-Mac backups from
    /// restoring into each other.
    func clientScope() async -> String?
}

/// Convenience defaults for backup test doubles and simple implementations.
public extension PairedMacBackingUp {
    func clientScope() async -> String? { nil }

    /// Default explicit-scope upload for test doubles that do not care about team routing.
    @discardableResult
    func upload(ops: [PairedMacBackupOp], teamID: String?) async -> Bool {
        await upload(ops: ops)
    }

    /// Default expected-account upload for test doubles that do not model auth.
    @discardableResult
    func upload(ops: [PairedMacBackupOp], teamID: String?, expectedUserID: String?) async -> Bool {
        await upload(ops: ops, teamID: teamID)
    }

    /// Default resolved-team upload for transports that predate the server echo:
    /// performs the plain upload and reports the stored team as unknown.
    @discardableResult
    func uploadReportingResolvedTeam(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?
    ) async -> PairedMacBackupUploadOutcome {
        PairedMacBackupUploadOutcome(
            succeeded: await upload(ops: ops, teamID: teamID, expectedUserID: expectedUserID),
            resolvedTeamID: nil
        )
    }

    /// Default explicit-scope fetch for test doubles that do not care about team routing.
    func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]? {
        await fetchAll()
    }

    /// Default snapshot fetch for test doubles/simple implementations that only
    /// model live records.
    func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        guard let records = await fetchAll() else { return nil }
        return PairedMacBackupSnapshot(records: records, deletedMacDeviceIDs: [])
    }

    /// Default explicit-scope snapshot fetch.
    func fetchSnapshot(teamID: String?) async -> PairedMacBackupSnapshot? {
        await fetchSnapshot()
    }

    /// Default expected-account snapshot fetch for test doubles that do not model auth.
    func fetchSnapshot(teamID: String?, expectedUserID: String?) async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: teamID)
    }
}
