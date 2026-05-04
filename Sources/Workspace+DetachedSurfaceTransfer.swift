import Foundation

extension Workspace {
    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let ttyName: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
        let isRemoteTerminal: Bool
        let remoteRelayPort: Int?
        let remoteCleanupConfiguration: WorkspaceRemoteConfiguration?

        func withRemoteCleanupConfiguration(_ configuration: WorkspaceRemoteConfiguration?) -> Self {
            Self(
                panelId: panelId,
                panel: panel,
                title: title,
                icon: icon,
                iconImageData: iconImageData,
                kind: kind,
                isLoading: isLoading,
                isPinned: isPinned,
                directory: directory,
                ttyName: ttyName,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                manuallyUnread: manuallyUnread,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remoteCleanupConfiguration: configuration
            )
        }
    }
}
