#if canImport(Network)
/// The production host: outbound connections go through Network.framework
/// (``IrxTunnelNetworkConnector``). Platforms without it inject a connector.
extension IrxTunnelHost {
    public init(
        limits: Limits = Limits(),
        policy: @escaping @Sendable () -> IrxTunnelDestinationPolicy,
        isAuthorized: @escaping @Sendable () -> Bool,
        // Not a closure-literal default: see IrxPeerEngine.init (cx-bsue).
        listPorts: (@Sendable () async -> [IrxListeningPort])? = nil,
        journal: IrxJournal? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.init(
            limits: limits,
            connector: IrxTunnelNetworkConnector(),
            policy: policy,
            isAuthorized: isAuthorized,
            listPorts: listPorts,
            journal: journal,
            now: now
        )
    }
}
#endif
