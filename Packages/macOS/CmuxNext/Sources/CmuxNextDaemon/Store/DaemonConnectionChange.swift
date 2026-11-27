/// Applies connection lifecycle facts and their original admission stamp together.
@MainActor
enum DaemonConnectionChange {
    case connected(DaemonIdentity, DaemonEventEnvelope?)
    case disconnected(String)
    case shutdown

    func apply(to store: DaemonStore) -> DaemonStore.Followup {
        store.connectionEpoch += 1
        switch self {
        case .connected(let identity, let envelope):
            // The presence kept across the drop is good only when this daemon replays every terminal's presence on
            // the new subscription and is the one that set it (hq#19373): any other connect starts blank.
            if !Self.keepsPresence(from: store.identity, to: identity) { store.clearPresence() }
            store.sideEvents.noteControl(envelope)
            store.session.connected(servesStateResources: identity.supports(DaemonCapability.stateResources.rawValue))
            store.connectionState = .connected(identity)
            store.noteConnected(envelope)
            store.noteHandshake(identity)
            return .resync
        case .disconnected(let reason):
            store.sideEvents.noteControl(nil)
            // Presence stays through the drop: a reconnect to the same daemon replays it, and any other connect
            // clears it (`keepsPresence`), so an agent that is still acting never blinks off in the sidebar.
            store.connectionState = .disconnected(reason)
            store.applyParkedBeforeDisconnect()
            store.onDisconnected?()
            // Nothing newer will arrive for commands sent on this transport.
            store.drainAppliedWaiters = true
            store.flushAppliedWaiters()
            return .none
        case .shutdown:
            store.sideEvents.noteControl(nil)
            store.clearPresence()
            store.connectionState = .disconnected("daemon shut down")
            store.applyParkedBeforeDisconnect()
            store.onDisconnected?()
            return .none
        }
    }

    /// True when a connect to `next` may keep the presence applied from `previous`: the same daemon generation and
    /// registry, and a daemon that replays every terminal's presence first on `subscribe`.
    static func keepsPresence(from previous: DaemonIdentity?, to next: DaemonIdentity) -> Bool {
        guard let previous else { return false }
        return previous.generation == next.generation && previous.registryID == next.registryID
            && next.supports(DaemonCapability.agentPresenceReplay.rawValue)
    }
}
