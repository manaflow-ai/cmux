import CmuxIrohTransport
import CmuxPeerTransport
import Foundation

/// Errors that end a bridged accept loop for good.
public enum PtxBridgeAcceptError: Error, Equatable, Sendable {
    case connectionClosed
}

/// Sorts one admitted connection's inbound raw streams into the legacy
/// shapes: the single control stream for the RPC service, application lanes
/// for the router, and per-stream rejections that keep the session alive.
///
/// Error contract mirrors the legacy server session exactly: a malformed or
/// role-invalid stream is reset with code 1 and surfaces as
/// `CmxIrohServerSessionError.applicationLaneRejected` (session continues);
/// connection close surfaces as `PtxBridgeAcceptError.connectionClosed`.
public actor PtxBridgeAcceptor {
    private enum AppEvent {
        case lane(CmxIrohLane, CmxIrohBidirectionalStream)
        case rejected
    }

    private let acceptsServerEvents: Bool
    private var appQueue: [AppEvent] = []
    private var appWaiters: [CheckedContinuation<AppEvent, any Error>] = []
    private var pendingControl: [PtxRawStream] = []
    private var controlWaiters: [CheckedContinuation<PtxRawStream, any Error>] = []
    private var pendingServerEvents: [(CmxIrohLane, CmxIrohBidirectionalStream)] = []
    private var serverEventWaiters:
        [CheckedContinuation<(CmxIrohLane, CmxIrohBidirectionalStream), any Error>] = []
    private var closed = false
    private var closeWatcher: Task<Void, Never>?

    /// - Parameter acceptsServerEvents: true on the phone side, where the
    ///   host legitimately opens server-event streams; false on the host
    ///   side, where a peer-opened one is a protocol violation.
    public init(acceptsServerEvents: Bool = false) {
        self.acceptsServerEvents = acceptsServerEvents
    }

    /// Wires an acceptor to one admitted connection: inbound raw streams flow
    /// in (it becomes the connection's single raw-stream owner), and
    /// connection close finishes every waiter.
    public static func attached(
        to connection: PtxConnection,
        acceptsServerEvents: Bool = false
    ) async -> PtxBridgeAcceptor {
        let acceptor = PtxBridgeAcceptor(acceptsServerEvents: acceptsServerEvents)
        await connection.onRawStream { descriptor, stream in
            await acceptor.ingest(descriptor: descriptor, stream: stream)
        }
        await acceptor.watchClose(of: connection)
        return acceptor
    }

    private func watchClose(of connection: PtxConnection) {
        closeWatcher = Task { [weak self] in
            _ = await connection.termination()
            await self?.finish()
        }
    }

    /// Routes one inbound raw stream by its descriptor.
    public func ingest(descriptor: String, stream: PtxRawStream) async {
        if closed {
            await stream.resetSend(errorCode: 1)
            await stream.stopReceiving(errorCode: 1)
            return
        }
        guard let parsed = try? PtxLaneDescriptor(encoded: descriptor),
            let lane = try? parsed.legacyLane()
        else {
            await reject(stream)
            return
        }
        switch lane {
        case .control:
            if let waiter = controlWaiters.first {
                controlWaiters.removeFirst()
                waiter.resume(returning: stream)
            } else {
                pendingControl.append(stream)
            }
        case .serverEvents:
            guard acceptsServerEvents else {
                await reject(stream)
                return
            }
            let event = (lane, CmxIrohBidirectionalStream(bridging: stream))
            if let waiter = serverEventWaiters.first {
                serverEventWaiters.removeFirst()
                waiter.resume(returning: event)
            } else {
                pendingServerEvents.append(event)
            }
        case .terminal, .artifact, .simulatorStream:
            deliver(.lane(lane, CmxIrohBidirectionalStream(bridging: stream)))
        }
    }

    /// Phone side: the next host-opened server-event stream.
    public func acceptServerEventStream() async throws -> (
        lane: CmxIrohLane, stream: CmxIrohBidirectionalStream
    ) {
        if !pendingServerEvents.isEmpty {
            return pendingServerEvents.removeFirst()
        }
        guard !closed else { throw PtxBridgeAcceptError.connectionClosed }
        return try await withCheckedThrowingContinuation { continuation in
            serverEventWaiters.append(continuation)
        }
    }

    /// The peer's control stream, in arrival order. The legacy stack opens
    /// exactly one per connection.
    public func nextControlStream() async throws -> PtxRawStream {
        if !pendingControl.isEmpty {
            return pendingControl.removeFirst()
        }
        guard !closed else { throw PtxBridgeAcceptError.connectionClosed }
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
            guard !closed else { throw PtxBridgeAcceptError.connectionClosed }
            event = try await withCheckedThrowingContinuation { continuation in
                appWaiters.append(continuation)
            }
        }
        switch event {
        case .lane(let lane, let stream):
            return (lane: lane, stream: stream)
        case .rejected:
            throw CmxIrohServerSessionError.applicationLaneRejected
        }
    }

    private func reject(_ stream: PtxRawStream) async {
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

    /// Ends the acceptor: queued streams are dropped, current and future
    /// waiters see `connectionClosed`.
    public func finish() {
        guard !closed else { return }
        closed = true
        closeWatcher?.cancel()
        closeWatcher = nil
        for waiter in appWaiters { waiter.resume(throwing: PtxBridgeAcceptError.connectionClosed) }
        appWaiters.removeAll()
        for waiter in controlWaiters {
            waiter.resume(throwing: PtxBridgeAcceptError.connectionClosed)
        }
        controlWaiters.removeAll()
        for waiter in serverEventWaiters {
            waiter.resume(throwing: PtxBridgeAcceptError.connectionClosed)
        }
        serverEventWaiters.removeAll()
        appQueue.removeAll()
        pendingControl.removeAll()
        pendingServerEvents.removeAll()
    }
}

/// Opens legacy-shaped lanes over one admitted v2 connection: the dialing
/// side of every bridged stream writes the descriptor, then owns the bytes.
public enum PtxBridgeDialer {
    /// One legacy application lane (terminal, artifact, simulator stream).
    public static func openLane(
        on connection: PtxConnection, lane: CmxIrohLane, priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let descriptor = try PtxLaneDescriptor(legacy: lane).encoded()
        let raw = try await connection.openRawStream(descriptor: descriptor)
        try? await raw.setSendPriority(priority)
        return CmxIrohBidirectionalStream(bridging: raw)
    }

    /// The connection's single control transport for the legacy RPC service.
    public static func openControlTransport(
        on connection: PtxConnection
    ) async throws -> PtxBridgeByteTransport {
        let descriptor = try PtxLaneDescriptor(lane: .control).encoded()
        let raw = try await connection.openRawStream(descriptor: descriptor)
        return PtxBridgeByteTransport(stream: raw)
    }

    /// Host side: one server-event send stream toward the phone.
    public static func openServerEventSendStream(
        on connection: PtxConnection, priority: Int32
    ) async throws -> any CmxIrohSendStream {
        let descriptor = try PtxLaneDescriptor(lane: .serverEvents).encoded()
        let raw = try await connection.openRawStream(descriptor: descriptor)
        try? await raw.setSendPriority(priority)
        return PtxBridgeSendStream(stream: raw)
    }
}
