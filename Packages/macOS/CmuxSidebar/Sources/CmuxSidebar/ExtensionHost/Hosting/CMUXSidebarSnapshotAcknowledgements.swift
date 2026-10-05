/// Tracks pushed snapshots for one transport generation and permission revision.
@_spi(CmuxHostTransport) public struct CMUXSidebarSnapshotAcknowledgements {
    private var generation: UInt64 = 0
    private var grantRevision: UInt64 = 0
    private var lastSentSequence: UInt64?

    /// Creates an empty acknowledgement tracker.
    public init() {}

    /// Clears delivery evidence when the transport or its permissions change.
    /// - Parameters:
    ///   - generation: Current transport generation.
    ///   - grantRevision: Current permission revision within that generation.
    public mutating func reset(generation: UInt64, grantRevision: UInt64) {
        self.generation = generation
        self.grantRevision = grantRevision
        lastSentSequence = nil
    }

    /// Records a successfully encoded snapshot pushed under the current grant.
    /// - Parameter sequence: Pushed snapshot sequence.
    public mutating func sent(_ sequence: UInt64) {
        lastSentSequence = sequence
    }

    /// Checks whether an acknowledgement belongs to a pushed snapshot.
    /// - Parameters:
    ///   - sequence: Applied snapshot sequence.
    ///   - generation: Transport generation that received the acknowledgement.
    ///   - grantRevision: Permission revision when the acknowledgement arrived.
    /// - Returns: Whether this grant and transport pushed that snapshot.
    public func accepts(_ sequence: UInt64, generation: UInt64, grantRevision: UInt64) -> Bool {
        self.generation == generation && self.grantRevision == grantRevision && lastSentSequence == sequence
    }
}
