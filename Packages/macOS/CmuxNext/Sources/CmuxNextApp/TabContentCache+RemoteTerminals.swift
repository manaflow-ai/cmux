import AppKit
import CmuxNextDaemon
import CmuxNextTerminal

/// Surfaces of remote-terminal tabs (plans/cmux-next/data-model.md 1.2b):
/// the tab lives in one session's layout, its terminal on another, so the
/// surface is keyed by the tab (like every surface) but attaches over the
/// terminal's own session by its public id, with no tab there.
extension TabContentCache {
    /// The surface for remote-terminal tab `key`, attached to terminal
    /// `resource` on `daemon` (created on demand; replaced when the
    /// terminal's session restarted or the reference changed).
    func remoteTerminal(for tab: TabModel, ref: RemoteTerminalRef, resource: ResourceID, daemon: DaemonService,
                        size: CellSize?) -> TerminalEntry? {
        let key = tab.id
        guard let generation = daemon.store.generation else { return nil }
        let validity = "remote#\(daemon.machineID)#\(ref.terminalID.rawValue)#\(resource.rawValue)#\(generation.rawValue)"
        if let entry = terminals[key], entry.validity == validity { return entry }
        discardTerminal(key)
        let target = DaemonTerminalIO.Target(
            attachment: .unplaced(terminalResourceID: resource, generation: generation),
            initialSize: size ?? CellSize(cols: 80, rows: 24))
        let render = ledger.isRendering(key)
        let io = DaemonTerminalIO(target: target, visible: render, policyBlocked: daemon.policyBlock.check, endpoint: { try await daemon.endpoint() })
        let session = TerminalSession(io: io, ownsGeometry: true)
        session.delegate = sessionDelegate
        // Its link state is the terminal's session's; it has no tab there.
        let entry = TerminalEntry(validity: validity, session: session, io: io, themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab),
                                  store: daemon.store, surface: TerminalAttachment.unresolvedSurface)
        terminals[key] = entry
        session.isRenderingSuspended = !render
        contentDidMount(key)
        return entry
    }

    /// Drops `key`'s surface (its session went away, or the tab closed);
    /// the pane presenting it lets the view go first.
    func discardTerminal(_ key: String) {
        guard let stale = terminals.removeValue(forKey: key) else { return }
        if let owner = ledger.remove(key) { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        applyLifecycle(lifecycle.send(.removed(key)))
        pendingMounts[key] = nil
        stale.close()
    }
}
