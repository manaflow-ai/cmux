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
}

/// Convenience defaults for backup test doubles and simple implementations.
public extension PairedMacBackingUp {
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
