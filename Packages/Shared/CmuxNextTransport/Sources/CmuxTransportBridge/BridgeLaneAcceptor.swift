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
    private var appQueue = FIFOQueue<AppEvent>()
    private var appWaiters = FIFOQueue<(id: Int, continuation: CheckedContinuation<AppEvent, any Error>)>()
    private var pendingControl = FIFOQueue<RawByteStream>()
    private var controlWaiters = FIFOQueue<(id: Int, continuation: CheckedContinuation<RawByteStream, any Error>)>()
    private var pendingServerEvents = FIFOQueue<(CmxIrohLane, CmxIrohBidirectionalStream)>()
    private var serverEventWaiters = FIFOQueue<(
        id: Int,
        continuation: CheckedContinuation<(lane: CmxIrohLane, stream: CmxIrohBidirectionalStream), any Error>
    )>()
    private var closed = false
    private var closeWatcher: Task<Void, Never>?
    private var waiterCounter = 0

    /// Queues are deliberately bounded: stream admission is already capped by
    /// the substrate, and retaining an arbitrary number of unconsumed events
    /// would let a peer turn rejected lanes into memory growth.
    private static let maxQueuedApplicationEvents = 64
    private static let maxQueuedControlStreams = 1
    private static let maxQueuedServerEventStreams = 16

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
                _ = controlWaiters.popFirst()
                waiter.continuation.resume(returning: stream)
            } else if pendingControl.count >= Self.maxQueuedControlStreams {
                await reject(stream)
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
                _ = serverEventWaiters.popFirst()
                waiter.continuation.resume(returning: event)
            } else if pendingServerEvents.count >= Self.maxQueuedServerEventStreams {
                await reject(stream)
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
            await deliver(.lane(lane, CmxIrohBidirectionalStream(bridging: stream)))
        }
    }

    /// Peer side: the next host-opened server-event stream.
    public func acceptServerEventStream() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        if !pendingServerEvents.isEmpty {
            return pendingServerEvents.popFirst()!
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
        waiterCounter += 1
        let waiterID = waiterCounter
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if closed {
                    continuation.resume(throwing: BridgeAcceptError.connectionClosed)
                } else if !pendingServerEvents.isEmpty {
                    continuation.resume(returning: pendingServerEvents.popFirst()!)
                } else {
                    serverEventWaiters.append((id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelServerEventWaiter(id: waiterID) }
        }
    }

    private func reject(_ stream: RawByteStream) async {
        await stream.resetSend(errorCode: 1)
        await stream.stopReceiving(errorCode: 1)
        await deliver(.rejected)
    }

    private func reject(_ stream: CmxIrohBidirectionalStream) async {
        await stream.sendStream.reset(errorCode: 1)
        await stream.receiveStream.stop(errorCode: 1)
    }

    private func deliver(_ event: AppEvent) async {
        if let waiter = appWaiters.first {
            _ = appWaiters.popFirst()
            switch event {
            case .lane(let lane, let stream):
                waiter.continuation.resume(returning: .lane(lane, stream))
            case .rejected:
                waiter.continuation.resume(returning: .rejected)
            }
        } else if case .rejected = event,
            appQueue.contains(where: { if case .rejected = $0 { true } else { false } })
        {
            // One queued rejection is enough to wake the legacy router; keep
            // coalescing hostile repeats instead of retaining one event each.
            return
        } else if appQueue.count < Self.maxQueuedApplicationEvents {
            appQueue.append(event)
        } else {
            switch event {
            case .rejected:
                return
            case .lane(_, let stream):
                await reject(stream)
            }
        }
    }

    /// The peer's control stream, in arrival order. The legacy stack opens
    /// exactly one per connection.
    public func nextControlStream() async throws -> RawByteStream {
        if !pendingControl.isEmpty {
            return pendingControl.popFirst()!
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
        waiterCounter += 1
        let waiterID = waiterCounter
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if closed {
                    continuation.resume(throwing: BridgeAcceptError.connectionClosed)
                } else if !pendingControl.isEmpty {
                    continuation.resume(returning: pendingControl.popFirst()!)
                } else {
                    controlWaiters.append((id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelControlWaiter(id: waiterID) }
        }
    }

    /// The legacy router's accept contract over bridged lanes.
    public func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        let event: AppEvent
        if !appQueue.isEmpty {
            event = appQueue.popFirst()!
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
            waiterCounter += 1
            let waiterID = waiterCounter
            event = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if closed {
                        continuation.resume(throwing: BridgeAcceptError.connectionClosed)
                    } else if !appQueue.isEmpty {
                        continuation.resume(returning: appQueue.popFirst()!)
                    } else {
                        appWaiters.append((id: waiterID, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelAppWaiter(id: waiterID) }
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
    public func finish() async {
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
        while let waiter = appWaiters.popFirst() {
            waiter.continuation.resume(throwing: BridgeAcceptError.connectionClosed)
        }
        while let waiter = controlWaiters.popFirst() {
            waiter.continuation.resume(throwing: BridgeAcceptError.connectionClosed)
        }
        while let waiter = serverEventWaiters.popFirst() {
            waiter.continuation.resume(throwing: BridgeAcceptError.connectionClosed)
        }
        while let event = appQueue.popFirst() {
            if case .lane(_, let stream) = event {
                await reject(stream)
            }
        }
        while let stream = pendingControl.popFirst() {
            await stream.resetSend(errorCode: 1)
            await stream.stopReceiving(errorCode: 1)
        }
        while let (_, stream) = pendingServerEvents.popFirst() {
            await reject(stream)
        }
    }

    /// Cancels one parked application-lane waiter and resumes it exactly once.
    private func cancelAppWaiter(id: Int) {
        guard let waiter = appWaiters.remove(where: { $0.id == id }) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Cancels one parked control-stream waiter and resumes it exactly once.
    private func cancelControlWaiter(id: Int) {
        guard let waiter = controlWaiters.remove(where: { $0.id == id }) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Cancels one parked server-event waiter and resumes it exactly once.
    private func cancelServerEventWaiter(id: Int) {
        guard let waiter = serverEventWaiters.remove(where: { $0.id == id }) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
