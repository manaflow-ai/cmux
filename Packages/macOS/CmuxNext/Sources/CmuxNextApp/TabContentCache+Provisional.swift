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

    /// The provisional view of `entry` attaches when its own tab gets its daemon surface, whether
    /// or not a pane applies anything then (no strip snapshot carries the surface): the one
    /// confirm, in its own turn (nothing re-enters a presentation), reported to ``onTerminalConfirmed``.
    func awaitConfirm(_ entry: TerminalEntry, of tab: TabModel, daemon: DaemonService) {
        entry.confirmation?.cancel()
        entry.confirming = tab
        entry.confirmation = Task { [weak self, weak entry, weak tab, weak daemon] in
            for await surface in ObservationStream({ [weak tab] in tab?.surface }) where surface.map(ProvisionalTab.isProvisional) != true { break }
            guard !Task.isCancelled, let self, let entry, let tab, let daemon, self.terminals[tab.id] === entry else { return }
            let target = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID, generation: daemon.store.generation)
            entry.confirm(validity: Self.terminalValidity(tab, daemon: daemon), target: target,
                          themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab), store: daemon.store)
            self.goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
            self.onTerminalConfirmed?(tab, daemon)
        }
    }
}
