/// The authenticated lane declaration at the beginning of every peer stream.
///
/// The control lane structurally requires the pair-grant credential and no
/// other lane can carry one, so the two invalid header shapes the old codec
/// rejected at runtime are unrepresentable here.
public enum PeerLaneHeader: Equatable, Sendable {
    /// The authenticated request, response, and lifecycle control lane.
    case control(credential: PeerPairGrantCredential)

    /// Ordered server events resumed after the optional last applied sequence.
    case serverEvents(cursor: UInt64?)

    /// One terminal's ordered stream resumed after the optional byte cursor.
    case terminal(resourceID: PeerResourceID, cursor: UInt64?)

    /// A low-priority artifact stream resumed at an exact byte offset.
    case artifact(resourceID: PeerResourceID, offset: UInt64)
}

/// A decoded lane header and the number of prefix bytes it consumed.
public struct PeerDecodedLaneHeader: Equatable, Sendable {
    /// The validated lane declaration.
    public let header: PeerLaneHeader

    /// The byte offset at which application payload begins.
    public let consumedByteCount: Int

    /// Creates a decoded-header result.
    ///
    /// - Parameters:
    ///   - header: The validated lane header.
    ///   - consumedByteCount: The exact number of framing bytes consumed.
    public init(header: PeerLaneHeader, consumedByteCount: Int) {
        self.header = header
        self.consumedByteCount = consumedByteCount
    }
}
