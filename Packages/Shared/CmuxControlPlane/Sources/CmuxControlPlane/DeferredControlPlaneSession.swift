public import CmuxMobileWire

/// A session handed out synchronously whose real session (a pool lease) is
/// made on first use; for adapters built inside synchronous factories (the
/// link registry's signaling relay).
public final class DeferredControlPlaneSession: ControlPlaneSession {
    private let resolved: Task<any ControlPlaneSession, Never>

    public init(_ make: @escaping @Sendable () async -> any ControlPlaneSession) {
        resolved = Task { await make() }
    }

    public func start() async { await resolved.value.start() }
    public func stop() async { await resolved.value.stop() }
    public func stateUpdates() async -> AsyncStream<ControlPlaneState> { await resolved.value.stateUpdates() }
    public func signalUpdates() async -> AsyncStream<SignalFrame> { await resolved.value.signalUpdates() }
    public func subscribe(_ stream: String) async -> AsyncStream<StreamUpdate> { await resolved.value.subscribe(stream) }
    public func unsubscribe(_ stream: String) async { await resolved.value.unsubscribe(stream) }
    public func submit(_ op: OpFrame) async throws -> OpOutcome { try await resolved.value.submit(op) }

    public func read(_ op: String, params: JSONValue, stream: String?) async throws -> ReadResultFrame {
        try await resolved.value.read(op, params: params, stream: stream)
    }

    public func sendSignal(_ signal: SignalFrame) async throws { try await resolved.value.sendSignal(signal) }

    public func setPresence(active: Bool, client: String) async throws {
        try await resolved.value.setPresence(active: active, client: client)
    }

    public func resendPending() async { await resolved.value.resendPending() }
}

extension HostSocketPool {
    /// A lease returned synchronously (see `DeferredControlPlaneSession`).
    public nonisolated func deferredSession(host: String, team: String? = nil) -> any ControlPlaneSession {
        DeferredControlPlaneSession { await self.session(host: host, team: team) }
    }
}
