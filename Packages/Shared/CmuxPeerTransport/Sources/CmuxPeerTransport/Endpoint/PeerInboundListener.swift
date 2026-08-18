public import CmuxPeerTransportCore
internal import Foundation
internal import IrohLib

/// Host-side accept loop. Pulls incoming connections off the endpoint and
/// hands each admitted handshake to the injected handler.
///
/// Bounded unauthenticated work: at most `maxConcurrentUnauthenticated`
/// connections may be between accept and handler completion; excess incoming
/// attempts are refused without a handshake. Handlers should return promptly
/// after their admission decision (spawning their own session task) so the
/// slot frees for the next unauthenticated peer.
public actor PeerInboundListener {
    /// Called once per admitted TLS handshake. Grant-based admission (the
    /// first control stream) happens inside the handler, above this layer.
    public typealias ConnectionHandler = @Sendable (PeerQuicConnection) async -> Void

    private let manager: PeerEndpointManager
    private let handler: ConnectionHandler
    private let maxConcurrentUnauthenticated: Int
    private var acceptTask: Task<Void, Never>?
    private var inFlight = 0
    private var nextHandlerID: UInt64 = 0
    private var handlerTasks: [UInt64: Task<Void, Never>] = [:]

    public init(
        manager: PeerEndpointManager,
        maxConcurrentUnauthenticated: Int = 8,
        handler: @escaping ConnectionHandler
    ) {
        precondition(maxConcurrentUnauthenticated > 0, "cap must be positive")
        self.manager = manager
        self.maxConcurrentUnauthenticated = maxConcurrentUnauthenticated
        self.handler = handler
    }

    deinit {
        acceptTask?.cancel()
        for (_, task) in handlerTasks {
            task.cancel()
        }
    }

    public var isRunning: Bool { acceptTask != nil }

    /// Number of connections currently between accept and handler return.
    public var pendingConnectionCount: Int { inFlight }

    /// Starts the accept loop against the endpoint of `generation`. Throws
    /// when the manager is inactive or the generation is stale. Idempotent
    /// while running.
    ///
    /// The loop ends when the endpoint closes (`acceptNext` returns nil after
    /// `deactivate()`/`recreate()`) or when `stop()` is called.
    public func start(generation: PeerTransportGeneration) async throws {
        guard acceptTask == nil else { return }
        let endpoint = try await manager.liveEndpoint(expecting: generation)
        acceptTask = Task { [weak self] in
            while !Task.isCancelled {
                // A parked acceptNext cannot be interrupted from Swift; it
                // returns nil once the endpoint closes, which is how
                // deactivate/recreate unblocks this loop.
                guard let incoming = await endpoint.acceptNext() else { return }
                guard !Task.isCancelled, let self else {
                    Task { try? await incoming.refuse() }
                    return
                }
                await self.dispatch(incoming: incoming, generation: generation)
            }
        }
    }

    /// Stops accepting and cancels in-flight handler tasks (handlers observe
    /// cooperative cancellation). Safe to call repeatedly.
    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        for (_, task) in handlerTasks {
            task.cancel()
        }
        handlerTasks.removeAll()
        inFlight = 0
    }

    // MARK: - Private

    private func dispatch(incoming: Incoming, generation: PeerTransportGeneration) {
        guard inFlight < maxConcurrentUnauthenticated else {
            // Over cap: drop before any handshake work.
            Task { try? await incoming.refuse() }
            return
        }
        inFlight += 1
        nextHandlerID &+= 1
        let id = nextHandlerID
        handlerTasks[id] = Task { [manager, handler] in
            do {
                let accepting = try await incoming.accept()
                let connection = try await accepting.connect()
                // Revalidate after the handshake awaits: a recreate during
                // the handshake makes this a zombie on a closed endpoint.
                if manager.isCurrent(generation), !Task.isCancelled {
                    await handler(PeerQuicConnection(wrapping: connection))
                } else {
                    try? connection.close(
                        errorCode: 0, reason: Data("listener superseded".utf8)
                    )
                }
            } catch {
                // Handshake failed (TLS/ALPN mismatch, peer went away).
                // Nothing to clean: the FFI handles drop with the task.
            }
            // This task inherits the actor's isolation, so the release is a
            // synchronous isolated call.
            self.handlerFinished(id: id)
        }
    }

    private func handlerFinished(id: UInt64) {
        // stop() may have already cleared the table; never double-release.
        guard handlerTasks.removeValue(forKey: id) != nil else { return }
        inFlight -= 1
    }
}
