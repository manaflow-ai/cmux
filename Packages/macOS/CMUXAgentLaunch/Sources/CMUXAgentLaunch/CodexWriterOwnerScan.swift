/// Descriptor holders discovered during a bounded process scan.
public struct CodexWriterOwnerScan: Sendable {
    /// Verified live holders, also useful for diagnostics when the scan was incomplete.
    public let owners: [CodexWriterOwner]
    /// Whether every same-user candidate could be inspected within the deadline.
    public let isComplete: Bool
}
