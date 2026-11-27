/// The independently readable and writable halves of one bidirectional stream.
public struct CmxIrohBidirectionalStream: Sendable {
    /// The peer-to-local stream half.
    public let receiveStream: any CmxIrohReceiveStream

    /// The local-to-peer stream half.
    public let sendStream: any CmxIrohSendStream

    /// Creates a bidirectional stream pair.
    ///
    /// - Parameters:
    ///   - receiveStream: The readable half.
    ///   - sendStream: The writable half.
    public init(
        receiveStream: any CmxIrohReceiveStream,
        sendStream: any CmxIrohSendStream
    ) {
        self.receiveStream = receiveStream
        self.sendStream = sendStream
    }
}
