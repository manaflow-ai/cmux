/// Applies connection lifecycle facts and their original admission stamp together.
@MainActor
enum DaemonConnectionChange {
    case connected(DaemonIdentity, DaemonEventEnvelope?)
    /// A drop; its envelope (the dropped link's last sequence) when the stream reported it.
    case disconnected(String, DaemonEventEnvelope?)
    case shutdown
    /// The mirrored connection is permanently failed (``DaemonStore/markFailed(_:)``, or its event stream threw).
    case failed(String)
    /// The store's run of the connection finished (`close()` ends its event stream with no envelope).
    case ended

    func apply(to store: DaemonStore) -> DaemonStore.Followup {
        store.connectionEpoch += 1
        // A wait for the session state's first snapshot ends with every connection change, never outliving its connection.
        store.session.connectionChanged()
        switch self {
        case .connected(let identity, let envelope):
            store.sideEvents.noteControl(envelope)
            store.session.connected(servesStateResources: identity.supports(DaemonCapability.stateResources.rawValue))
            store.connectionState = .connected(identity)
            store.noteHandshake(identity)
            return .resync
        case .disconnected(let reason, let envelope):
            store.sideEvents.noteControl(nil)
            store.clearPresence()
            store.connectionState = .disconnected(reason)
            store.onDisconnected?()
            // Nothing newer will arrive for commands sent on this link. A wait for a sequence past the drop's
            // (the next link's, read after a reconnect) is not this link's: it stays for that link's events.
            store.endAppliedWaits(through: envelope?.sequence ?? .max)
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
            store.endAppliedWaits(through: .max)
            store.flushAppliedWaiters()
            return .none
        case .ended:
            // No echo or barrier will come for its commands.
            store.endAppliedWaits(through: .max)
            store.flushAppliedWaiters()
            return .none
        }
    }
}
