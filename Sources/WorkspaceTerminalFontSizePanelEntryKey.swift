import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    enum EntryKey: Hashable {
        case workspace(UUID)
        case workspaceDock(UUID)
        case remoteMirror(UUID)
        case remotePane(
            mirrorId: UUID,
            paneId: Int,
            panelId: UUID
        )
        case windowDock(UUID)
    }
}
