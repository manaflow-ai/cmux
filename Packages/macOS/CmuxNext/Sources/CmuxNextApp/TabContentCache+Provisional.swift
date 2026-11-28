import CmuxNextDaemon

/// The terminal view of a pane Cmd+D shows before the daemon replied
/// (plans/cmux-next/remote-state-ownership.md S3): keyed by its client-minted tab id, so the
/// daemon's tab under the same id reuses the view and its session (no surface swap), and the
/// view attaches only then (``TerminalTargetGate``).
extension TabContentCache {
    /// Tab id plus the daemon generation and surface the view attached to; a provisional tab's
    /// view has no surface yet.
    static func terminalValidity(_ tab: TabModel, daemon: DaemonService) -> String {
        if ProvisionalTab.isProvisional(surface: tab.surface) { return "\(daemon.machineID)#\(tab.id)#provisional" }
        return "\(daemon.machineID)#\(tab.id)#\(daemon.store.generation?.rawValue ?? "")#\(tab.surface.rawValue)"
    }

    /// The provisional view of `tab`'s id, now attached to the daemon's `tab`; nil when there is none.
    func confirmedProvisional(_ tab: TabModel, validity: String, target: TerminalAttachment.Target,
                              store: DaemonStore) -> TerminalEntry? {
        guard !ProvisionalTab.isProvisional(surface: tab.surface), let entry = terminals[tab.id], entry.gate != nil else {
            return nil
        }
        entry.confirm(validity: validity, target: target, store: store)
        return entry
    }
}
