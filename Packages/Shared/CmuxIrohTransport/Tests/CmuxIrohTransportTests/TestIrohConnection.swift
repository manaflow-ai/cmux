import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohConnection: CmxIrohConnection {
    private let peerIdentity: CmxIrohPeerIdentity
    private var bidirectionalStreams: [CmxIrohBidirectionalStream]
    private var receiveStreams: [any CmxIrohReceiveStream]
    private var incomingStreamLimits: [(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    )] = []
    private var closeCalls: [(code: UInt64, reason: String)] = []
    private let closeStream: AsyncStream<(code: UInt64, reason: String)>
    private let closeContinuation: AsyncStream<(code: UInt64, reason: String)>.Continuation

    init(
        remoteIdentity: CmxIrohPeerIdentity,
        bidirectionalStreams: [CmxIrohBidirectionalStream],
        receiveStreams: [any CmxIrohReceiveStream] = []
    ) {
        peerIdentity = remoteIdentity
        self.bidirectionalStreams = bidirectionalStreams
        self.receiveStreams = receiveStreams
        let closes = AsyncStream<(code: UInt64, reason: String)>.makeStream()
        closeStream = closes.stream
        closeContinuation = closes.continuation
    }

    func remoteIdentity() -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func setIncomingStreamLimits(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    ) {
        incomingStreamLimits.append((
            maximumBidirectionalStreamCount,
            maximumUnidirectionalStreamCount
        ))
    }

    func openBidirectionalStream() throws -> CmxIrohBidirectionalStream {
        guard !bidirectionalStreams.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        return bidirectionalStreams.removeFirst()
    }

    func acceptBidirectionalStream() throws -> CmxIrohBidirectionalStream {
        try openBidirectionalStream()
    }

    func openSendStream() throws -> any CmxIrohSendStream {
        guard let sendStream = bidirectionalStreams.first?.sendStream else {
            throw TestIrohTransportError.unsupported
        }
        return sendStream
    }

    func acceptReceiveStream() throws -> any CmxIrohReceiveStream {
        guard !receiveStreams.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        return receiveStreams.removeFirst()
    }

    func close(errorCode: UInt64, reason: String) {
        closeCalls.append((errorCode, reason))
        closeContinuation.yield((errorCode, reason))
    }

    func observedCloseCallCount() -> Int {
        closeCalls.count
    }

    func observedIncomingStreamLimits() -> [String] {
        incomingStreamLimits.map {
            "\($0.maximumBidirectionalStreamCount):\($0.maximumUnidirectionalStreamCount)"
        }
    }

    func closeEvents() -> AsyncStream<(code: UInt64, reason: String)> {
        closeStream
    }
}
