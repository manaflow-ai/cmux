/// The backup transport seam used by backup mirroring and restore.
public protocol PairedMacBackingUp: Sendable {
    /// Push backup mutations best-effort.
    func upload(ops: [PairedMacBackupOp]) async

    /// Fetch the caller's full backed-up list, or `nil` on transport/auth failure.
    func fetchAll() async -> [PairedMacBackupRecord]?
}
