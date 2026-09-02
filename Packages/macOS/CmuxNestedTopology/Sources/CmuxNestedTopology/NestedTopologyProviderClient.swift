/// Provider-neutral client for nested topology providers.
///
/// Implementations speak only their provider transport (for Herdr: newline-delimited
/// JSON over a local Unix socket). They must not shell out to CLIs and must not
/// mutate cmux workspace / Bonsplit state. Mutations are capability-gated; when a
/// method is unavailable, clients must fail closed (never synthesize keystrokes
/// or shell commands).
public protocol NestedTopologyProviderClient: Sendable {
    /// Negotiates compatibility and returns handshake metadata for this connection generation.
    func handshake() async throws -> NestedProviderHandshake

    /// Fetches a full topology snapshot for the configured host attachment.
    func snapshot() async throws -> NestedTopologySnapshot

    /// Streams provider topology events, reconnecting with a full resnapshot on recoverable gaps.
    func events() -> AsyncThrowingStream<NestedTopologyEvent, any Error>

    /// Focuses one nested node via the provider's typed focus method.
    ///
    /// Requires ``NestedProviderCapability/topologyFocusV1``. Must not invent
    /// topology locally — callers reconcile from subsequent events/snapshots.
    func focus(nodeID: NestedNodeID) async throws
}
