public import CmuxMobileWire

/// What a feature needs from one control-plane socket: a `ControlPlaneClient`
/// it owns alone, or a lease on a socket several features share
/// (`HostSocketPool`: one HostDO socket per Mac for workspaces, tasks,
/// presence and signaling). Streams returned here may each be iterated by
/// their caller; a lease fans them out.
public protocol ControlPlaneSession: Sendable {
    func start() async
    /// Ends this session's use of the socket (a lease releases it; the last
    /// release closes it).
    func stop() async
    /// The current state, then every change.
    func stateUpdates() async -> AsyncStream<ControlPlaneState>
    /// Signals relayed to this install.
    func signalUpdates() async -> AsyncStream<SignalFrame>
    func subscribe(_ stream: String) async -> AsyncStream<StreamUpdate>
    func unsubscribe(_ stream: String) async
    func submit(_ op: OpFrame) async throws -> OpOutcome
    func read(_ op: String, params: JSONValue, stream: String?) async throws -> ReadResultFrame
    func sendSignal(_ signal: SignalFrame) async throws
    func setPresence(active: Bool, client: String) async throws
    func resendPending() async
}

extension ControlPlaneSession {
    public func read(_ op: String, params: JSONValue = .object([:])) async throws -> ReadResultFrame {
        try await read(op, params: params, stream: nil)
    }

    public func setPresence(active: Bool) async throws {
        try await setPresence(active: active, client: "ios")
    }
}

/// A client used alone: its own streams, each readable once.
extension ControlPlaneClient: ControlPlaneSession {
    public func stateUpdates() -> AsyncStream<ControlPlaneState> { states }
    public func signalUpdates() -> AsyncStream<SignalFrame> { signals }
}
