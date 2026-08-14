import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    /// Live pane surface identities in the same order as the rendered layout.
    var surfaceIDsInLayoutOrder: [UUID] {
        paneIDsInOrder.compactMap { panel(forPane: $0)?.id }
    }

    /// Projects the mirror's authoritative pane order into stable identities
    /// consumable by the control socket without duplicating mutable topology.
    func controlPanes() -> [RemoteTmuxControlPane] {
        paneIDsInOrder.compactMap(controlPane(tmuxPaneID:))
    }

    func controlPane(tmuxPaneID: Int) -> RemoteTmuxControlPane? {
        guard let paneID = syntheticPaneID(forPane: tmuxPaneID),
              let panel = panel(forPane: tmuxPaneID) else { return nil }
        return RemoteTmuxControlPane(
            tmuxPaneID: tmuxPaneID,
            paneID: paneID,
            panel: panel,
            title: title(forPane: tmuxPaneID),
            isFocused: tmuxPaneID == activePaneId
        )
    }

    func controlPane(paneID: UUID) -> RemoteTmuxControlPane? {
        controlPanes().first(where: { $0.paneID.id == paneID })
    }

    func controlPane(surfaceID: UUID) -> RemoteTmuxControlPane? {
        controlPanes().first(where: { $0.panel.id == surfaceID })
    }

    func activeControlPane() -> RemoteTmuxControlPane? {
        guard let activePaneId else { return nil }
        return controlPane(tmuxPaneID: activePaneId)
    }

    /// Resolves the active pane without formatting its control-plane title.
    func activeControlSurfaceProjection() -> (surfaceID: UUID, paneID: UUID?, panel: TerminalPanel)? {
        guard let activePaneId,
              let panel = panel(forPane: activePaneId) else { return nil }
        return (panel.id, syntheticPaneID(forPane: activePaneId)?.id, panel)
    }
}
