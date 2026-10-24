/// Applies connection lifecycle facts and their original admission stamp together.
@MainActor
enum DaemonConnectionChange {
    case connected(DaemonIdentity, DaemonEventEnvelope?)
    case disconnected(String)
    case shutdown
    /// The mirrored connection is permanently failed (``DaemonStore/markFailed(_:)``, or its event stream threw).
    case failed(String)
    /// The store's run of the connection finished (`close()` ends its event stream with no envelope).
    case ended

    func apply(to store: DaemonStore) -> DaemonStore.Followup {
        store.connectionEpoch += 1
        switch self {
        case .connected(let identity, let envelope):
            store.sideEvents.noteControl(envelope)
            store.session.connected(servesStateResources: identity.supports(DaemonCapability.stateResources.rawValue))
            store.connectionState = .connected(identity)
            store.noteHandshake(identity)
            return .resync
        case .disconnected(let reason):
            store.sideEvents.noteControl(nil)
            store.clearPresence()
            store.connectionState = .disconnected(reason)
            store.onDisconnected?()
            // Nothing newer will arrive for commands sent on this transport.
            store.drainAppliedWaiters = true
            store.flushAppliedWaiters()
            return .none
        case .shutdown:
            store.sideEvents.noteControl(nil)
            store.clearPresence()
            store.connectionState = .disconnected("daemon shut down")
            store.onDisconnected?()
            return .none
        case .failed(let message):
            store.connectionState = .failed(message)
            // Nothing newer will arrive for commands sent on this connection.
            store.drainAppliedWaiters = true
            store.flushAppliedWaiters()
            return .none
        case .ended:
            // No echo or barrier will come for its commands.
            store.drainAppliedWaiters = true
            store.flushAppliedWaiters()
            return .none
        }
    }
}
