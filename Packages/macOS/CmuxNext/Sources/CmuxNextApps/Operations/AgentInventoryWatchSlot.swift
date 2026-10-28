import CmuxNextDaemon

/// Owns callbacks and bounded admission for one immutable route generation.
@MainActor
final class AgentInventoryWatchSlot {
    let route: AgentInventoryWatchRoute
    var carrier: AgentInventoryWatchCarrier?
    var token: UInt64?
    var admission: Task<Void, Never>?
    var receipt: AgentInventoryWatchReceipt?
    var early: [AgentInventoryWatchEvent] = []
    var retired = false
    private var retirement: Task<Void, Never>?

    init(route: AgentInventoryWatchRoute) { self.route = route }

    /// Invalidates callbacks synchronously before any asynchronous cleanup.
    func retire() -> Task<Void, Never>? {
        if retired { return retirement }
        retired = true
        if let token { route.events.unsubscribe(token) }
        token = nil
        admission?.cancel()
        if let carrier {
            // task-owner: the manager retains bounded conditional cleanup on its original transport.
            // Off main: the disable runs on the watch's actor and touches no slot state.
            retirement = Task { @concurrent in try? await carrier.watch.disable() }
        }
        return retirement
    }
}
