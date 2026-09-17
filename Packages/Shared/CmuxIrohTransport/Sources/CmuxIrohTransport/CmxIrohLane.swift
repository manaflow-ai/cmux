/// The independent application lane carried by one Iroh QUIC stream.
public enum CmxIrohLane: Equatable, Sendable {
    /// The authenticated request, response, and lifecycle control lane.
    case control

    /// Ordered server events resumed after the optional last applied sequence.
    case serverEvents(cursor: UInt64?)

    /// One terminal's ordered stream resumed after the optional byte cursor.
    case terminal(resourceID: CmxIrohResourceID, cursor: UInt64?)

    /// One full-first semantic-scene presentation with exact drawable geometry.
    case terminalScene(CmxIrohTerminalSceneLaneRequest)

    /// A low-priority artifact stream resumed at an exact byte offset.
    case artifact(resourceID: CmxIrohResourceID, offset: UInt64)
}
