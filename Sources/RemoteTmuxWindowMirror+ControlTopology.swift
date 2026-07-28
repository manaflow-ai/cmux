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
            return RemoteTmuxControlPane(
                tmuxPaneID: tmuxPaneID,
                paneID: paneID,
                panel: panel,
                title: title(forPane: tmuxPaneID),
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
}
