public import CmuxNextDaemon

extension DaemonService {
    /// The identity of this daemon's live handshake: nil unless the app holds a connection and the
    /// store reads it connected. ``identity`` keeps the last handshake's after the transport drops,
    /// and ``connection`` stays set while it reconnects, also when that reconnect fails; neither is
    /// the daemon there now (review of #38130: an update skipped a machine on an old reading).
    public var liveIdentity: DaemonIdentity? {
        Self.liveIdentity(identity, connected: connection != nil, state: store.connectionState)
    }

    /// ``liveIdentity`` from the identity the store holds (the current or last handshake's),
    /// whether the service holds a connection, and the store's connection state.
    public nonisolated static func liveIdentity(_ held: DaemonIdentity?, connected: Bool,
                                                state: DaemonConnectionState) -> DaemonIdentity? {
        guard connected, case .connected = state else { return nil }
        return held
    }
}
