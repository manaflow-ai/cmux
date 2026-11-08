public import CmuxNextDaemon

extension DaemonService {
    /// The identity of this daemon's handshake while the app holds a connection to it.
    public var liveIdentity: DaemonIdentity? {
        Self.liveIdentity(identity, connected: connection != nil, state: store.connectionState)
    }

    /// ``liveIdentity`` from the identity the store holds (the current or last handshake's),
    /// whether the service holds a connection, and the store's connection state.
    public nonisolated static func liveIdentity(_ held: DaemonIdentity?, connected: Bool,
                                                state: DaemonConnectionState) -> DaemonIdentity? {
        connected ? held : nil
    }
}
