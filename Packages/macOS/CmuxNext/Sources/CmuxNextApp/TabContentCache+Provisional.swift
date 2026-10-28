import CmuxNextDaemon
import CmuxNextWakeups

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

    /// The one confirm: `entry` attaches when its tab gets its daemon surface (no pane applies), in a
    /// task of its own (nothing re-enters a presentation), reported to ``onTerminalConfirmed``. The
    /// tab's surface is followed as a ServiceObservation: the attach must happen while the pane is
    /// hidden too, and only a change of that surface reads it again.
    func awaitConfirm(_ entry: TerminalEntry, of tab: TabModel, daemon: DaemonService) {
        entry.confirmation?.cancel()
        entry.confirmation = nil
        entry.confirming = tab
        guard ProvisionalTab.isProvisional(surface: tab.surface) else {
            mainWork.post(.visible, owner: Self.confirmOwner) { [weak self, weak entry, weak tab, weak daemon] in
                guard let self, let entry, let tab, let daemon else { return }
                self.confirm(entry, of: tab, daemon: daemon)
            }
            return
        }
        entry.confirmation = ServiceObservation(.visible, owner: Self.confirmOwner, on: mainWork) { [weak tab] in
            tab.map { ProvisionalTab.isProvisional(surface: $0.surface) } ?? false
        } apply: { [weak self, weak entry, weak tab, weak daemon] provisional in
            guard !provisional, let self, let entry, let tab, let daemon else { return }
            self.confirm(entry, of: tab, daemon: daemon)
        }
    }

    private static let confirmOwner = "TabContentCache.confirmTerminal"

    /// Attaches `entry` to `tab`'s daemon surface, unless the entry left the cache or waits for another tab.
    private func confirm(_ entry: TerminalEntry, of tab: TabModel, daemon: DaemonService) {
        guard entry.confirming === tab, terminals[tab.id] === entry else { return }
        entry.confirmation?.cancel()
        entry.confirmation = nil
        let target = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID, generation: daemon.store.generation)
        entry.confirm(validity: Self.terminalValidity(tab, daemon: daemon), target: target,
                      themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab), store: daemon.store)
        goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
        onTerminalConfirmed?(tab, daemon)
    }
}
