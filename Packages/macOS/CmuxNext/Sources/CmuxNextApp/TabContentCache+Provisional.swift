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

    /// The stand-in terminal of a New Terminal Tab (Ctrl-`, ``NewTerminalTabCommand``) whose create chose `tab`'s
    /// terminal id, moved to `tab`: the same view and session attach to the daemon's tab, as a split's provisional pane
    /// does, so the keys the stand-in sent by terminal id and the ones still in its input lane reach the PTY in order.
    /// The key holds waiting for the stand-in follow it. Nil when `tab` is a stand-in itself, or no stand-in chose its id.
    func adoptStandIn(for tab: TabModel, daemon: DaemonService) -> TerminalEntry? {
        guard !ProvisionalTab.isProvisional(surface: tab.surface), let terminal = tab.terminalID, terminals[tab.id] == nil,
              let (key, entry) = terminals.first(where: { $0.key != tab.id && $0.value.gate != nil && $0.value.standInTerminal == terminal })
        else { return nil }
        entry.standInTerminal = nil // once: no later tab with that id takes it from `tab`
        terminals[key] = nil
        release(key, displacing: false) // the pane keeps the view: it shows it again as `tab`'s
        terminals[tab.id] = entry
        goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
        awaitConfirm(entry, of: tab, daemon: daemon)
        contentDidMount(tab.id)
        keyRouter?.creationInputCoordinator.standInAdopted(key, as: tab.id)
        return entry
    }

    /// Stand-in `key`, which a pane withdraws (it shows another tab: its daemon tab, which it then asks content for),
    /// goes to its daemon tab now when the store has it, instead of to the warm set, whose eviction would close its
    /// input lane with keys in it. True when it moved.
    func adoptsWithdrawnStandIn(_ key: String) -> Bool {
        guard let entry = terminals[key], let terminal = entry.standInTerminal, let daemon = entry.standInDaemon,
              let tab = daemon.store.tab(terminal: terminal),
              !ProvisionalTab.isProvisional(surface: tab.surface) else { return false }
        return adoptStandIn(for: tab, daemon: daemon) != nil
    }

    /// The one confirm: `entry` attaches when its tab gets its daemon surface (no pane applies), in its
    /// own turn (nothing re-enters a presentation), reported to ``onTerminalConfirmed``.
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
