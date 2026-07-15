import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohEventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func observedEvents() -> [String] {
        events
    }
}

actor TestIrohConnection: CmxIrohConnection, CmxIrohConnectionPathInspecting {
    private let peerIdentity: CmxIrohPeerIdentity
    private var bidirectionalStreams: [CmxIrohBidirectionalStream]
    private var receiveStreams: [any CmxIrohReceiveStream]
    private let natTraversalAuthorizationError: TestIrohTransportError?
    private let eventRecorder: TestIrohEventRecorder?
    private var selectedPath: CmxIrohObservedConnectionPath
    private let selectedPathStream: AsyncStream<CmxIrohObservedConnectionPath>
    private let selectedPathContinuation: AsyncStream<CmxIrohObservedConnectionPath>.Continuation
    private var incomingStreamLimits: [(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    )] = []
    private var bidirectionalStreamOpenCount = 0
    private var receiveStreamAcceptCount = 0
    private var natTraversalAuthorizationAttemptCount = 0
    private var natTraversalActivationCount = 0
    private var natTraversalAuthorized = false
    private var closeCalls: [(code: UInt64, reason: String)] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private let closeStream: AsyncStream<(code: UInt64, reason: String)>
    private let closeContinuation: AsyncStream<(code: UInt64, reason: String)>.Continuation

    init(
        remoteIdentity: CmxIrohPeerIdentity,
        bidirectionalStreams: [CmxIrohBidirectionalStream],
        receiveStreams: [any CmxIrohReceiveStream] = [],
        natTraversalAuthorizationError: TestIrohTransportError? = nil,
        eventRecorder: TestIrohEventRecorder? = nil,
        selectedPath: CmxIrohObservedConnectionPath = .unavailable
    ) {
        peerIdentity = remoteIdentity
        self.bidirectionalStreams = bidirectionalStreams
        self.receiveStreams = receiveStreams
        self.natTraversalAuthorizationError = natTraversalAuthorizationError
        self.eventRecorder = eventRecorder
        self.selectedPath = selectedPath
        let pathChanges = AsyncStream<CmxIrohObservedConnectionPath>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        selectedPathStream = pathChanges.stream
        selectedPathContinuation = pathChanges.continuation
        selectedPathContinuation.yield(selectedPath)
        let closes = AsyncStream<(code: UInt64, reason: String)>.makeStream()
        closeStream = closes.stream
        closeContinuation = closes.continuation
    }

    func remoteIdentity() -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func observedSelectedPath() -> CmxIrohObservedConnectionPath {
        selectedPath
    }

    func observedSelectedPathChanges() -> AsyncStream<CmxIrohObservedConnectionPath> {
        selectedPathStream
    }

    func setObservedSelectedPath(_ path: CmxIrohObservedConnectionPath) {
        selectedPath = path
        selectedPathContinuation.yield(path)
    }

    func setIncomingStreamLimits(
        maximumBidirectionalStreamCount: UInt64,
        maximumUnidirectionalStreamCount: UInt64
    ) async {
        incomingStreamLimits.append((
            maximumBidirectionalStreamCount,
            maximumUnidirectionalStreamCount
        ))
        await eventRecorder?.record(
            "connection.limits:\(maximumBidirectionalStreamCount):\(maximumUnidirectionalStreamCount)"
        )
    }

    func openBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        guard !bidirectionalStreams.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        bidirectionalStreamOpenCount += 1
        await eventRecorder?.record("connection.openBidirectionalStream")
        return bidirectionalStreams.removeFirst()
    }

    func acceptBidirectionalStream() async throws -> CmxIrohBidirectionalStream {
        try await openBidirectionalStream()
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
        receiveStreamAcceptCount += 1
        return receiveStreams.removeFirst()
    }

    func close(errorCode: UInt64, reason: String) {
        let firstClose = closeCalls.isEmpty
        closeCalls.append((errorCode, reason))
        closeContinuation.yield((errorCode, reason))
        if firstClose {
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilClosed() async {
        if !closeCalls.isEmpty { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func authorizeNatTraversal() async throws {
        natTraversalAuthorizationAttemptCount += 1
        await eventRecorder?.record("connection.authorizeNatTraversal")
        if let natTraversalAuthorizationError {
            throw natTraversalAuthorizationError
        }
        guard !natTraversalAuthorized else { return }
        natTraversalAuthorized = true
        natTraversalActivationCount += 1
    }

    func observedCloseCallCount() -> Int {
        closeCalls.count
    }

    func observedIncomingStreamLimits() -> [String] {
        incomingStreamLimits.map {
            "\($0.maximumBidirectionalStreamCount):\($0.maximumUnidirectionalStreamCount)"
        }
    }

    func observedBidirectionalStreamOpenCount() -> Int {
        bidirectionalStreamOpenCount
    }

    func observedReceiveStreamAcceptCount() -> Int {
        receiveStreamAcceptCount
    }

    func observedNatTraversalAuthorizationAttemptCount() -> Int {
        natTraversalAuthorizationAttemptCount
    }

    func observedNatTraversalActivationCount() -> Int {
        natTraversalActivationCount
    }

    func closeEvents() -> AsyncStream<(code: UInt64, reason: String)> {
        closeStream
    }
}
