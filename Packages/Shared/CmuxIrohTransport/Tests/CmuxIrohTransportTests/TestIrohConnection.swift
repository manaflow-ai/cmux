import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohConnection: CmxIrohConnection {
    private let peerIdentity: CmxIrohPeerIdentity
    private var bidirectionalStreams: [CmxIrohBidirectionalStream]
    private var receiveStreams: [any CmxIrohReceiveStream]
    private var closeCalls: [(code: UInt64, reason: String)] = []

    init(
        remoteIdentity: CmxIrohPeerIdentity,
        bidirectionalStreams: [CmxIrohBidirectionalStream],
        receiveStreams: [any CmxIrohReceiveStream] = []
    ) {
        peerIdentity = remoteIdentity
        self.bidirectionalStreams = bidirectionalStreams
        self.receiveStreams = receiveStreams
    }

    func remoteIdentity() -> CmxIrohPeerIdentity {
        peerIdentity
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
    }

    func observedCloseCallCount() -> Int {
        closeCalls.count
    }
}
