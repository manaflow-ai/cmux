import Foundation

extension Workspace {
    func forkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        guard panels[panelId] is TerminalPanel else { return .notTerminalPanel }
        guard let snapshot = forkableAgentSnapshot(forPanelId: panelId) else {
            return .noAgentSnapshot
        }
        switch ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemoteTerminalSurface(panelId)
        ) {
        case .supportedWithoutProbe:
            return .available
        case .requiresProbe:
            return .requiresProbe
        case .unsupported:
            return .unsupported
        }
    }
}
