/// The backup transport seam used by backup mirroring and restore.
public protocol PairedMacBackingUp: Sendable {
    /// Push backup mutations best-effort.
    func upload(ops: [PairedMacBackupOp]) async

    /// Push backup mutations best-effort for an already-captured team scope.
    func upload(ops: [PairedMacBackupOp], teamID: String?) async

    /// Fetch the caller's full backed-up list, or `nil` on transport/auth failure.
    func fetchAll() async -> [PairedMacBackupRecord]?

    /// Fetch the caller's full backed-up list for an already-captured team scope.
    func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]?
}

/// Convenience defaults for backup test doubles and simple implementations.
public extension PairedMacBackingUp {
    /// Default explicit-scope upload for test doubles that do not care about team routing.
    func upload(ops: [PairedMacBackupOp], teamID: String?) async {
        await upload(ops: ops)
    }

    /// Default explicit-scope fetch for test doubles that do not care about team routing.
    func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]? {
        await fetchAll()
    }
}
