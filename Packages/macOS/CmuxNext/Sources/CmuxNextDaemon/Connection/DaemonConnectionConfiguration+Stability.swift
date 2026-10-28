extension DaemonConnectionConfiguration {
    /// Whether a connection of this configuration to `endpoint` counts its daemon's stability
    /// (p09-observability-109): the app's main connection (the one with the local heartbeat) to a daemon on this
    /// Mac. A bridge's server is another machine's; a page relay shares the main connection's daemon.
    func countsStability(of endpoint: DaemonEndpoint) -> Bool {
        localHeartbeat && role != .pageRelay && endpoint.bridge == nil
    }
}
