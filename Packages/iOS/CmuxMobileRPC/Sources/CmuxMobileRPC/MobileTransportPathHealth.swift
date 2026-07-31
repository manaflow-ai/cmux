public import CMUXMobileCore

/// Credential-free health classification of the live connection's selected
/// transport path (docs/transport-plane.md, D3).
///
/// `unknown` means the active transport exposes no path observation (raw
/// TCP, loopback, scripted test transports); callers must preserve their
/// pre-gate behavior for it.
public enum MobileTransportPathHealth: Equatable, Sendable {
    /// The transport reports a usable selected path (direct, private
    /// network, or relay) for the live session.
    case healthy
    /// The transport reports no usable path for the live session.
    case noPath
    /// No path information is available for the active transport.
    case unknown
}

/// Async source for the exact live connection's current path health.
///
/// Implementations must never mutate connection state and must answer from
/// already-observed state (no network round trips): the value gates
/// escalation decisions on hot recovery paths. The request is the immutable
/// transport admission identity owned by `MobileCoreRPCClient`; requiring it
/// prevents a healthy background Mac from masking a dead foreground Mac.
public typealias MobileTransportPathHealthProvider =
    @Sendable (CmxByteTransportRequest) async -> MobileTransportPathHealth

public extension MobileSyncRuntime {
    /// Optional credential-free path-health source for the live connection.
    /// A nil provider keeps legacy escalation behavior (health `unknown`).
    var transportPathHealthProvider: MobileTransportPathHealthProvider? { nil }
}
