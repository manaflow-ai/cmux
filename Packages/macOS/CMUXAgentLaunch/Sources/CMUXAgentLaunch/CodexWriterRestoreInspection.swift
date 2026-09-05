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

    /// Finds one runtime in the unique descriptor holder's observed ancestry.
    /// Revalidate both the process and runtime generations before navigating.
    /// - Parameter surfaces: Candidates from current local terminal runtimes.
    /// - Returns: One unambiguous candidate, or nil for missing/duplicate evidence.
    public func mappedSurface(in surfaces: [CodexWriterSurfaceIdentity]) -> CodexWriterSurfaceIdentity? {
        guard lock?.state == .active, ownerScanComplete, owners.count == 1, let owner = owners.first else { return nil }
        let matches = surfaces.filter {
            $0.foregroundPID > 1 && $0.foregroundPID <= Int(Int32.max)
                && $0.ttyDevice > 0 && owner.ttyDevice == $0.ttyDevice
                && owner.ancestorPIDs.contains(Int32($0.foregroundPID))
        }
        return matches.count == 1 ? matches.first : nil
    }
}
