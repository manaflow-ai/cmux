import Foundation

@MainActor
extension RemoteTmuxWindowMirror {
    /// Projects the mirror's authoritative pane order into stable identities
    /// consumable by the control socket without duplicating mutable topology.
    func controlPanes() -> [RemoteTmuxControlPane] {
        let focusedTmuxPaneID = activePaneId ?? paneIDsInOrder.first
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
                isFocused: tmuxPaneID == focusedTmuxPaneID
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
        let panes = controlPanes()
        return panes.first(where: \.isFocused) ?? panes.first
    }
}
