public import Foundation

/// Scriptable in-memory transport for ``AgentSyncEngine`` tests.
public actor FixtureSyncTransport: AgentSyncTransport {
    /// Request handler closure used by the fixture transport.
    public typealias RequestHandler = @Sendable (_ params: Data) async throws -> Data

    /// Stream of injected connection events.
    public nonisolated let connectionEvents: AsyncStream<AgentSyncConnectionEvent>

    private let connectionContinuation: AsyncStream<AgentSyncConnectionEvent>.Continuation
    private var handlers: [String: RequestHandler]
    private var subscription: (id: UUID, topics: Set<String>, continuation: AsyncStream<AgentSyncFrame>.Continuation)?
    private var recordedCalls: [AgentSyncTransportCall]

    /// Creates an empty fixture transport.
    public init() {
        let pair = AsyncStream<AgentSyncConnectionEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        connectionEvents = pair.stream
        connectionContinuation = pair.continuation
        handlers = [:]
        subscription = nil
        recordedCalls = []
    }

    /// Registers a request handler for one method.
    /// - Parameters:
    ///   - method: The RPC method to handle.
    ///   - handler: The scripted request handler.
    public func setHandler(method: String, handler: @escaping RequestHandler) {
        handlers[method] = handler
    }

    /// Returns the recorded transport calls.
    /// - Returns: The call log.
    public func calls() -> [AgentSyncTransportCall] {
        recordedCalls
    }

    /// Removes all recorded transport calls.
    public func resetCalls() {
        recordedCalls.removeAll()
    }

    /// Injects a connection event into ``connectionEvents``.
    /// - Parameter event: The event to inject.
    public func injectConnectionEvent(_ event: AgentSyncConnectionEvent) {
        connectionContinuation.yield(event)
    }

    /// Injects a raw event frame to matching subscribers.
    /// - Parameters:
    ///   - topic: The topic carrying the frame.
    ///   - payload: The raw JSON payload.
    public func injectFrame(topic: String, payload: Data) {
        guard let subscription, subscription.topics.contains(topic) else { return }
        let frame = AgentSyncFrame(topic: topic, payload: payload)
        subscription.continuation.yield(frame)
    }

    /// Sends a scripted request.
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: Raw JSON parameters.
    /// - Returns: The scripted response.
    public func request(method: String, params: Data) async throws -> Data {
        recordedCalls.append(AgentSyncTransportCall(kind: .request, method: method, params: params))
        guard let handler = handlers[method] else {
            throw FixtureSyncTransportError.unhandledRequest(method)
        }
        return try await handler(params)
    }

    /// Creates a fixture subscription.
    /// - Parameter topics: Topics to subscribe to.
    /// - Returns: A stream receiving injected matching frames.
    public func subscribe(topics: [String]) async throws -> AsyncStream<AgentSyncFrame> {
        recordedCalls.append(AgentSyncTransportCall(kind: .subscribe, topics: topics))
        subscription?.continuation.finish()
        let id = UUID()
        let pair = AsyncStream<AgentSyncFrame>.makeStream(bufferingPolicy: .bufferingNewest(256))
        subscription = (id, Set(topics), pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscription(id: id) }
        }
        return pair.stream
    }

    /// Records an unsubscribe operation and replaces the active topic set.
    /// - Parameter topics: Topics to unsubscribe from.
    public func unsubscribe(topics: [String]) async {
        recordedCalls.append(AgentSyncTransportCall(kind: .unsubscribe, topics: topics))
        guard let active = subscription else { return }
        let remaining = active.topics.subtracting(topics)
        if remaining.isEmpty {
            active.continuation.finish()
            subscription = nil
        } else {
            subscription = (active.id, remaining, active.continuation)
        }
    }

    private func removeSubscription(id: UUID) {
        guard subscription?.id == id else { return }
        subscription = nil
    }
}
