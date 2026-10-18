import CmuxNextDaemon
import CmuxNextCompat

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
                              daemon: DaemonService) -> TerminalEntry? {
        guard !ProvisionalTab.isProvisional(surface: tab.surface), let entry = terminals[tab.id], entry.gate != nil else {
            return nil
        }
        entry.confirm(validity: validity, target: target, themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab), store: daemon.store)
        return entry
    }

    /// The provisional view of `entry` attaches when its own tab gets its daemon surface, whether
    /// or not a pane applies anything then (no strip snapshot carries the surface). This task is
    /// the one report of the confirm (``onTerminalConfirmed``), in its own turn: a presenter that
    /// confirmed first does not end it, and nothing re-enters a presentation.
    func awaitConfirm(_ entry: TerminalEntry, of tab: TabModel, daemon: DaemonService) {
        entry.confirmation = Task { [weak self, weak entry, weak tab, weak daemon] in
            for await surface in ObservationStream({ [weak tab] in tab?.surface }) {
                guard let self, let entry, let tab, let daemon, let surface else { return }
                guard !ProvisionalTab.isProvisional(surface: surface) else { continue }
                guard self.terminals[tab.id] === entry else { return }
                _ = self.terminal(for: tab, daemon: daemon)
                self.onTerminalConfirmed?(tab, daemon)
                return
            }
        }
    }
}
