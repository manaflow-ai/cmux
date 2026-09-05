/// Descriptor holders discovered during a bounded process scan.
public struct CodexWriterOwnerScan: Sendable {
    /// Verified live holders, also useful for diagnostics when the scan was incomplete.
    public let owners: [CodexWriterOwner]
    /// Whether every same-user candidate could be inspected within the deadline.
    public let isComplete: Bool

    /// Creates descriptor evidence from an injected discovery implementation.
    /// - Parameters:
    ///   - owners: Verified process generations opening the inspected inode.
    ///   - isComplete: False when inspection was skipped, denied, or timed out.
    public init(owners: [CodexWriterOwner], isComplete: Bool) {
        self.owners = owners
        self.isComplete = isComplete
    }
}
