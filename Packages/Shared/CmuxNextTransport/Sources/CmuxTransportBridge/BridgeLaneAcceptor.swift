import CmuxIrohTransport
import CmuxNextTransport
import Foundation

/// Errors that end a bridged accept loop for good.
public enum BridgeAcceptError: Error, Equatable, Sendable {
    case connectionClosed
}

/// Sorts one admitted connection's inbound raw streams into the legacy
/// shapes: the single control stream for the RPC service, application lanes
/// for the router, per-stream rejections that keep the session alive.
///
/// Mirrors the legacy server session's contract exactly: a malformed or
/// peer-invalid stream is reset with code 1 and surfaces as
/// `CmxIrohServerSessionError.applicationLaneRejected` (session keeps going);
/// connection close surfaces as `BridgeAcceptError.connectionClosed`.
public actor BridgeLaneAcceptor {
    private enum AppEvent {
        case lane(CmxIrohLane, CmxIrohBidirectionalStream)
        case rejected
    }

    private let acceptsServerEvents: Bool
    private var appQueue: [AppEvent] = []
    private var appWaiters: [CheckedContinuation<AppEvent, any Error>] = []
    private var pendingControl: [RawByteStream] = []
    private var controlWaiters: [CheckedContinuation<RawByteStream, any Error>] = []
    private var pendingServerEvents: [(CmxIrohLane, CmxIrohBidirectionalStream)] = []
    private var serverEventWaiters:
        [CheckedContinuation<(CmxIrohLane, CmxIrohBidirectionalStream), any Error>] = []
    private var closed = false
    private var closeWatcher: Task<Void, Never>?

    /// - Parameter acceptsServerEvents: true on the peer (phone) side, where
    ///   the host legitimately opens server-event streams; false on the host
    ///   side, where a peer-opened one is a protocol violation.
    public init(acceptsServerEvents: Bool = false) {
        self.acceptsServerEvents = acceptsServerEvents
    }

    /// Wires an acceptor to one admitted connection: inbound raw streams
    /// flow in, and connection close finishes every waiter.
    public static func attached(
        to connection: IrohPeerConnection,
        acceptsServerEvents: Bool = false
    ) async -> BridgeLaneAcceptor {
        let acceptor = BridgeLaneAcceptor(acceptsServerEvents: acceptsServerEvents)
        if BridgeDebugLog.enabled {
            BridgeDebugLog.lanes.notice(
                """
                acceptor \(BridgeDebugLog.id(acceptor), privacy: .public) attached \
                conn=\(BridgeDebugLog.id(connection), privacy: .public) \
                acceptsServerEvents=\(acceptsServerEvents, privacy: .public)
                """)
        }
        await connection.onRawStream { preamble, stream in
            await acceptor.ingest(preamble: preamble, stream: stream)
        }
        await acceptor.watchClose(of: connection)
        return acceptor
    }

    private func watchClose(of connection: IrohPeerConnection) {
        closeWatcher = Task { [weak self] in
            let termination = await connection.termination()
            if BridgeDebugLog.enabled, let self {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) finishing: \
                    conn=\(BridgeDebugLog.id(connection), privacy: .public) terminated \
                    code=\(termination?.code ?? "unparsed", privacy: .public)
                    """)
            }
            await self?.finish()
        }
    }

    /// Routes one inbound raw stream by its preamble.
    public func ingest(preamble: String, stream: RawByteStream) async {
        if closed {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest DROPPED \
                    (acceptor closed) preamble=\(preamble, privacy: .public)
                    """)
            }
            await stream.resetSend(errorCode: 1)
            await stream.stopReceiving(errorCode: 1)
            return
        }
        guard let lane = try? BridgeLaneDescriptor.lane(fromPreamble: preamble) else {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.error(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest REJECTED \
                    reason=invalid-descriptor preamble=\(preamble, privacy: .public)
                    """)
            }
            await reject(stream)
            return
        }
        switch lane {
        case .control:
            let hadWaiter = !controlWaiters.isEmpty
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest lane=control \
                    delivery=\(hadWaiter ? "waiter" : "queued", privacy: .public) \
                    queued=\(self.pendingControl.count + (hadWaiter ? 0 : 1), privacy: .public)
                    """)
            }
            if let waiter = controlWaiters.first {
                controlWaiters.removeFirst()
                waiter.resume(returning: stream)
            } else {
                pendingControl.append(stream)
            }
        case .serverEvents:
            guard acceptsServerEvents else {
                // Server events are host-opened; on the host side a
                // peer-opened one is a protocol violation.
                if BridgeDebugLog.enabled {
                    BridgeDebugLog.lanes.error(
                        """
                        acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest REJECTED \
                        reason=peer-opened-server-events (protocol violation on host side) \
                        preamble=\(preamble, privacy: .public)
                        """)
                }
                await reject(stream)
                return
            }
            let hadWaiter = !serverEventWaiters.isEmpty
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest lane=server-events \
                    delivery=\(hadWaiter ? "waiter" : "queued", privacy: .public) \
                    queued=\(self.pendingServerEvents.count + (hadWaiter ? 0 : 1), privacy: .public)
                    """)
            }
            let event = (lane, CmxIrohBidirectionalStream(bridging: stream))
            if let waiter = serverEventWaiters.first {
                serverEventWaiters.removeFirst()
                waiter.resume(returning: event)
            } else {
                pendingServerEvents.append(event)
            }
        case .terminal, .artifact, .simulatorStream:
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) ingest app lane \
                    preamble=\(preamble, privacy: .public) \
                    delivery=\(self.appWaiters.isEmpty ? "queued" : "waiter", privacy: .public)
                    """)
            }
            deliver(.lane(lane, CmxIrohBidirectionalStream(bridging: stream)))
        }
    }

    /// Peer side: the next host-opened server-event stream.
    public func acceptServerEventStream() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        if !pendingServerEvents.isEmpty {
            return pendingServerEvents.removeFirst()
        }
        guard !closed else {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) \
                    acceptServerEventStream -> connectionClosed
                    """)
            }
            throw BridgeAcceptError.connectionClosed
        }
        return try await withCheckedThrowingContinuation { continuation in
            serverEventWaiters.append(continuation)
        }
    }

    private func reject(_ stream: RawByteStream) async {
        await stream.resetSend(errorCode: 1)
        await stream.stopReceiving(errorCode: 1)
        deliver(.rejected)
    }

    private func deliver(_ event: AppEvent) {
        if let waiter = appWaiters.first {
            appWaiters.removeFirst()
            switch event {
            case .lane(let lane, let stream):
                waiter.resume(returning: .lane(lane, stream))
            case .rejected:
                waiter.resume(returning: .rejected)
            }
        } else {
            appQueue.append(event)
        }
    }

    /// The peer's control stream, in arrival order. The legacy stack opens
    /// exactly one per connection.
    public func nextControlStream() async throws -> RawByteStream {
        if !pendingControl.isEmpty {
            return pendingControl.removeFirst()
        }
        guard !closed else {
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.notice(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) \
                    nextControlStream -> connectionClosed
                    """)
            }
            throw BridgeAcceptError.connectionClosed
        }
        return try await withCheckedThrowingContinuation { continuation in
            controlWaiters.append(continuation)
        }
    }

    /// The legacy router's accept contract over bridged lanes.
    public func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        let event: AppEvent
        if !appQueue.isEmpty {
            event = appQueue.removeFirst()
        } else {
            guard !closed else {
                if BridgeDebugLog.enabled {
                    BridgeDebugLog.lanes.notice(
                        """
                        acceptor \(BridgeDebugLog.id(self), privacy: .public) \
                        acceptBidirectionalLane -> connectionClosed
                        """)
                }
                throw BridgeAcceptError.connectionClosed
            }
            event = try await withCheckedThrowingContinuation { continuation in
                appWaiters.append(continuation)
            }
        }
        switch event {
        case .lane(let lane, let stream):
            return (lane: lane, stream: stream)
        case .rejected:
            if BridgeDebugLog.enabled {
                BridgeDebugLog.lanes.error(
                    """
                    acceptor \(BridgeDebugLog.id(self), privacy: .public) \
                    acceptBidirectionalLane -> applicationLaneRejected (session continues)
                    """)
            }
            throw CmxIrohServerSessionError.applicationLaneRejected
        }
    }

    /// Ends the acceptor: queued streams are dropped, current and future
    /// waiters see `connectionClosed`.
    public func finish() {
        guard !closed else { return }
        closed = true
        if BridgeDebugLog.enabled {
            BridgeDebugLog.lanes.notice(
                """
                acceptor \(BridgeDebugLog.id(self), privacy: .public) finish: \
                appWaiters=\(self.appWaiters.count, privacy: .public) \
                ctlWaiters=\(self.controlWaiters.count, privacy: .public) \
                sevWaiters=\(self.serverEventWaiters.count, privacy: .public) \
                droppedApp=\(self.appQueue.count, privacy: .public) \
                droppedCtl=\(self.pendingControl.count, privacy: .public) \
                droppedSev=\(self.pendingServerEvents.count, privacy: .public)
                """)
        }
        closeWatcher?.cancel()
        closeWatcher = nil
        for waiter in appWaiters { waiter.resume(throwing: BridgeAcceptError.connectionClosed) }
        appWaiters.removeAll()
        for waiter in controlWaiters {
            waiter.resume(throwing: BridgeAcceptError.connectionClosed)
        }
        controlWaiters.removeAll()
        for waiter in serverEventWaiters {
            waiter.resume(throwing: BridgeAcceptError.connectionClosed)
        }
        serverEventWaiters.removeAll()
        appQueue.removeAll()
        pendingControl.removeAll()
        pendingServerEvents.removeAll()
    }
}
