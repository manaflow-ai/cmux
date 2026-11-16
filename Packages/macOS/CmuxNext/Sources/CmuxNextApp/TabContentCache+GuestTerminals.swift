import CmuxNextDaemon
import CmuxNextTerminal

/// A second live view of a daemon terminal, for a window that shows a workspace another window
/// also shows (two windows on one space, plans/cmux-next/spaces-overhaul-DESIGN.md rule 6).
///
/// The cache keeps one surface per tab, presented by one pane (`SurfaceLedger`). A Ghostty surface
/// draws into one view, so the second window gets a surface of its own with its own attach: to the
/// daemon it is one more participant of the same terminal, as a phone or another Mac is. The pane
/// that shows it owns it (`PaneController.guestTerminal`): it is made when the pane shows the tab
/// and closed when the pane shows another tab or goes. It never enters the ledger, so it can never
/// take the surface of the window that owns the workspace.
extension TabContentCache {
    /// A new view of `tab`'s terminal, attached over `daemon`. `visible`: its pane is on screen.
    func guestTerminal(for tab: TabModel, daemon: DaemonService, visible: Bool) -> TerminalEntry {
        let attach = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                               generation: daemon.store.generation)
        let target = DaemonTerminalIO.Target(attachment: attach, initialSize: tab.size ?? CellSize(cols: 80, rows: 24),
                                             cursorDefault: .user)
        let io = DaemonTerminalIO(target: target, resizes: resizes, visible: visible, remoteShell: !daemon.isLocal,
                                  uploadsPasteboardFiles: daemon.machineID != "local", policyBlocked: daemon.policyBlock.check,
                                  endpoint: { try await daemon.endpoint() })
        let session = makeSession(io: io, tab: tab, daemon: daemon)
        session.showsTerminal(daemon.terminalIdentity(of: tab), carrying: nil)
        let entry = TerminalEntry(validity: daemon.terminalViewValidity(of: tab), session: session, io: io,
                                  themeKey: TerminalThemeKey(machine: daemon.machineID, tab: tab), store: daemon.store, surface: tab.surface)
        guestTerminals[ObjectIdentifier(session)] = (tab.id, entry)
        session.delegate = sessionDelegate // after the session resolves to its tab (`tabKey(for:)`)
        session.isRenderingSuspended = !visible
        return entry
    }

    /// The pane that showed guest view `entry` let it go.
    func closeGuestTerminal(_ entry: TerminalEntry) {
        guestTerminals[ObjectIdentifier(entry.session)] = nil
        entry.close()
    }
}
