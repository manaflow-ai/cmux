extension SocketControlServer {
    /// Captures listener state for an off-actor socket health probe.
    ///
    /// The returned value is immutable and ``Sendable``. Call
    /// ``SocketListenerHealthProbeInput/resolve(using:)`` on a utility
    /// executor when the caller must avoid synchronous filesystem work on the
    /// main actor.
    public nonisolated func listenerHealthProbeInput(
        expectedSocketPath: String
    ) -> SocketListenerHealthProbeInput {
        let snapshot = listenerStateSnapshot()
        return SocketListenerHealthProbeInput(
            isRunning: snapshot.isRunning,
            acceptLoopAlive: snapshot.acceptLoopAlive,
            listenerSocketPath: snapshot.socketPath,
            expectedSocketPath: expectedSocketPath,
            boundSocketPathIdentity: snapshot.boundSocketPathIdentity
        )
    }
}
