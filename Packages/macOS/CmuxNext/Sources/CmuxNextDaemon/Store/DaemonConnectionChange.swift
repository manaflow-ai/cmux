/// Applies connection lifecycle facts and their original admission stamp together.
@MainActor
enum DaemonConnectionChange {
    case connected(DaemonIdentity, DaemonEventEnvelope?)
    case disconnected(String)
    case shutdown

    func apply(to store: DaemonStore) -> DaemonStore.Followup {
        store.connectionEpoch += 1
        store.crashKeys?.set(.daemonEpoch, UInt64(clamping: store.connectionEpoch))
        // A wait for the old connection's sequence ends now (its batch already advanced past the events before
        // this one): the next connection numbers its events from its own serial.
        store.resumeAppliedWaits()
        store.resumeConnectionWaits()
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
        }
    }
}
