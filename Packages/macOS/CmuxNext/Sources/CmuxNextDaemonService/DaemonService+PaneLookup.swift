public import CmuxNextDaemon

@MainActor
extension Array where Element == DaemonService {
    /// The pane with public or resource id `id` and its daemon, only when exactly one daemon holds
    /// it: forks keep pane ids, so a bare id two machines share names no pane (cmux#30755).
    public func uniquePane(_ id: String) -> (daemon: DaemonService, pane: PaneModel)? {
        var found: (daemon: DaemonService, pane: PaneModel)?
        for daemon in self {
            guard let pane = daemon.store.pane(idOrResource: id) else { continue }
            guard found == nil else { return nil }
            found = (daemon, pane)
        }
        return found
    }
}
