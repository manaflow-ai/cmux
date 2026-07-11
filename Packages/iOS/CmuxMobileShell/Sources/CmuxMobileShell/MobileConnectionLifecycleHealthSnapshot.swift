/// Immutable connection health used while reducing a lifecycle event.
struct MobileConnectionLifecycleHealthSnapshot {
    var connected: Bool
    var hasClient: Bool
    var hasListener: Bool
    var eventStreamFresh: Bool
    var canReconnectPersistedMac: Bool

    var hasHealthyEventStream: Bool {
        connected && hasClient && hasListener && eventStreamFresh
    }
}
