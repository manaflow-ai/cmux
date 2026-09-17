/// A preflight result shared by terminal execution and Vault continuation.
public struct CodexWriterRestoreInspection: Sendable {
    /// Local kernel lock evidence, or nil when the final argv selects a remote provider.
    public let lock: CodexWriterLockInspection?
    /// Current descriptor holders. Empty when discovery is inconclusive or the lock changed.
    public let owners: [CodexWriterOwner]
    private let ownerScanComplete: Bool

    init(lock: CodexWriterLockInspection?, owners: [CodexWriterOwner], ownerScanComplete: Bool = true) {
        self.lock = lock
        self.owners = owners
        self.ownerScanComplete = ownerScanComplete
    }

    /// Whether the local ownership preflight permits process startup.
    public var permitsLaunch: Bool { lock == nil || lock?.state == .available }

    /// Whether every same-user process could be inspected for the lock descriptor.
    public var isOwnerScanComplete: Bool { ownerScanComplete }

    /// The one verified holder, when discovery was complete and unambiguous.
    public var uniqueOwner: CodexWriterOwner? {
        guard lock?.state == .active, ownerScanComplete, owners.count == 1 else { return nil }
        return owners.first
    }
}
