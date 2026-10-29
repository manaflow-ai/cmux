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

    /// The stand-in terminal of a New Terminal Tab (Ctrl-`, ``NewTerminalTabCommand``) whose create chose `tab`'s
    /// terminal id, moved to `tab`: the same view and session attach to the daemon's tab, as a split's provisional pane
    /// does, so the keys the stand-in sent by terminal id and the ones still in its input lane reach the PTY in order
    /// (first-seconds-evidence.md). Nil when `tab` is a stand-in itself, has no terminal id, or no stand-in chose it.
    func adoptStandIn(for tab: TabModel, daemon: DaemonService) -> TerminalEntry? {
        guard !ProvisionalTab.isProvisional(surface: tab.surface), let terminal = tab.terminalID, terminals[tab.id] == nil,
              let (key, entry) = terminals.first(where: { $0.key != tab.id && $0.value.gate != nil && $0.value.standIn?.terminal == terminal })
        else { return nil }
        entry.standIn = nil // once: no later tab with that id takes it from `tab`
        terminals[key] = nil
        moveNode(key, to: tab.id) // the view's node goes with it
        createTabs.rekey(key, to: tab.id) // the daemon's tab waits for the stand-in's first frame
        release(key, displacing: false) // the pane keeps the view: it shows it again as `tab`'s
        terminals[tab.id] = entry
        goneTabs.track(tab.id, in: daemon.store) { [weak self] in self?.release($0) }
        awaitConfirm(entry, of: tab, daemon: daemon)
        contentDidMount(tab.id)
        onStandInAdopted?(key, tab.id)
        return entry
    }

    /// Stand-in `key`, which a pane withdraws (it shows another tab: its daemon tab, in `showSelectionNow`, which then
    /// asks for that tab's content), goes to its daemon tab now when the store has it, instead of to the warm set,
    /// whose eviction would close its input lane with keys in it. True when it moved.
    func adoptsWithdrawnStandIn(_ key: String) -> Bool {
        guard let link = terminals[key]?.standIn, let daemon = link.daemon,
              let tab = daemon.store.tab(terminal: link.terminal), !ProvisionalTab.isProvisional(surface: tab.surface) else { return false }
        return adoptStandIn(for: tab, daemon: daemon) != nil
    }

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
