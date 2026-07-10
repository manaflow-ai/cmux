import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    /// Projects the mirror's authoritative pane order into stable identities
    /// consumable by the control socket without duplicating mutable topology.
    func controlPanes() -> [RemoteTmuxControlPane] {
        return paneIDsInOrder.compactMap { tmuxPaneID in
            guard let paneID = syntheticPaneID(forPane: tmuxPaneID),
                  let panel = panel(forPane: tmuxPaneID) else {
                return nil
            }
            let header = paneHeaderLabels[tmuxPaneID]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return RemoteTmuxControlPane(
                tmuxPaneID: tmuxPaneID,
                paneID: paneID,
                panel: panel,
                title: header.isEmpty ? panel.displayTitle : header,
                isFocused: tmuxPaneID == activePaneId
            )
        }
    }

    func controlPane(paneID: UUID) -> RemoteTmuxControlPane? {
        controlPanes().first(where: { $0.paneID.id == paneID })
    }

    func controlPane(surfaceID: UUID) -> RemoteTmuxControlPane? {
        controlPanes().first(where: { $0.panel.id == surfaceID })
    }

    func activeControlPane() -> RemoteTmuxControlPane? {
        guard let activePaneId else { return nil }
        return controlPanes().first(where: { $0.tmuxPaneID == activePaneId })
    }

    /// Drops app-lifetime control refs before a projected pane leaves the
    /// mirror-owned topology; these panels bypass Workspace panel lifecycle.
    func cleanupControlPane(tmuxPaneID: Int) {
        guard let paneID = syntheticPaneID(forPane: tmuxPaneID),
              let surfaceID = panel(forPane: tmuxPaneID)?.id else { return }
        onControlPaneRemoved?(paneID, surfaceID)
    }
}
