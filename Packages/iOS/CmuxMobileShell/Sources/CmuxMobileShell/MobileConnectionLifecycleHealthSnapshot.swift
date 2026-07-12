/// Immutable connection health used while reducing a lifecycle event.
struct MobileConnectionLifecycleHealthSnapshot {
    var connected: Bool
    var hasClient: Bool
    var hasListener: Bool
    var eventStreamFresh: Bool
    var canReconnectPersistedMac: Bool

    /// Whether the stream's connection topology is still attached.
    /// Event silence is evaluated by the liveness probe, because an idle stream
    /// can remain healthy without producing events.
    var hasAttachedEventStream: Bool {
        connected && hasClient && hasListener
    }
}
