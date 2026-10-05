/// Tracks pushed snapshots for one transport generation and permission revision.
@_spi(CmuxHostTransport) public struct CMUXSidebarSnapshotAcknowledgements {
    private var generation: UInt64 = 0
    private var grantRevision: UInt64 = 0
    private var sentSequences: [UInt64] = []
    private var lastIssuedSequence: UInt64?

    /// Creates an empty acknowledgement tracker.
    public init() {}

    /// Clears delivery evidence when the transport or its permissions change.
    /// - Parameters:
    ///   - generation: Current transport generation.
    ///   - grantRevision: Current permission revision within that generation.
    public mutating func reset(generation: UInt64, grantRevision: UInt64) {
        if self.generation != generation { lastIssuedSequence = nil }
        self.generation = generation
        self.grantRevision = grantRevision
        sentSequences.removeAll(keepingCapacity: true)
    }

    /// Reserves a unique monotonic wire sequence, including across grant changes.
    /// - Parameter minimum: Sequence provided by the workspace snapshot cache.
    /// - Returns: A wire sequence, or nil if the UInt64 transport space is exhausted.
    public mutating func reserveSequence(atLeast minimum: UInt64) -> UInt64? {
        if let previous = lastIssuedSequence {
            guard previous < UInt64.max else { return nil }
            lastIssuedSequence = max(minimum, previous + 1)
        } else {
            lastIssuedSequence = minimum
        }
        return lastIssuedSequence
    }

    /// Records a successfully encoded snapshot pushed under the current grant.
    /// - Parameter sequence: Pushed snapshot sequence.
    public mutating func sent(_ sequence: UInt64) {
        if sentSequences.last != sequence { sentSequences.append(sequence) }
        if sentSequences.count > 64 { sentSequences.removeFirst(sentSequences.count - 64) }
    }

    /// Checks whether an acknowledgement belongs to a pushed snapshot.
    /// - Parameters:
    ///   - sequence: Applied snapshot sequence.
    ///   - generation: Transport generation that received the acknowledgement.
    ///   - grantRevision: Permission revision when the acknowledgement arrived.
    /// - Returns: Whether this grant and transport pushed that snapshot.
    public func accepts(_ sequence: UInt64, generation: UInt64, grantRevision: UInt64) -> Bool {
        self.generation == generation && self.grantRevision == grantRevision && sentSequences.contains(sequence)
    }
}
