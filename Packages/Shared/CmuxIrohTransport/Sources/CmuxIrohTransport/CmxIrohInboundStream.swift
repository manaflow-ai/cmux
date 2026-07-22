/// A peer-created unidirectional stream after its lane header is removed.
public struct CmxIrohInboundStream: Sendable {
    /// The declared server-event or artifact lane.
    public let lane: CmxIrohLane

    /// The readable application payload after the consumed header.
    public let receiveStream: any CmxIrohReceiveStream

    /// Creates a decoded inbound stream.
    ///
    /// - Parameters:
    ///   - lane: The peer-declared application lane.
    ///   - receiveStream: The stream with any over-read bytes preserved.
    public init(lane: CmxIrohLane, receiveStream: any CmxIrohReceiveStream) {
        self.lane = lane
        self.receiveStream = receiveStream
    }
}
