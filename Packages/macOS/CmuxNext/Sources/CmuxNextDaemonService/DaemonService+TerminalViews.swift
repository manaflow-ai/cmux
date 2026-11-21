public import CmuxNextDaemon

/// The keys of a tab's terminal view in the App's content cache: when a view is stale, and which
/// daemon terminal it shows.
extension DaemonService {
    /// Tab id plus the daemon generation and surface the view attached to; a provisional tab's
    /// view has no surface yet.
    public func terminalViewValidity(of tab: TabModel) -> String {
        if ProvisionalTab.isProvisional(surface: tab.surface) { return "\(machineID)#\(tab.id)#provisional" }
        return "\(machineID)#\(tab.id)#\(store.generation?.rawValue ?? "")#\(tab.surface.rawValue)"
    }

    /// The daemon terminal `tab` shows, whatever the daemon's generation: its `term_` id, else the
    /// tab's content id (a terminal the restarted daemon still adopts is listed with no runtime
    /// surface, so no terminal id yet, but keeps its content id), else its surface handle. A new view
    /// of the same terminal (a daemon restart: a new generation) keeps showing the old view's frame.
    public func terminalIdentity(of tab: TabModel) -> String {
        let terminal = (tab.terminalResourceID ?? tab.snapshot.contentResourceID).map { "term:\($0.rawValue)" }
        return "\(machineID)#\(terminal ?? "surface:\(tab.surface.rawValue)")"
    }

    /// The daemon terminal a remote-terminal tab shows: the terminal's own session and resource,
    /// whatever that session's generation.
    public func remoteTerminalIdentity(_ ref: RemoteTerminalRef, resource: ResourceID) -> String {
        "remote#\(machineID)#\(ref.terminalID.rawValue)#\(resource.rawValue)"
    }
}
