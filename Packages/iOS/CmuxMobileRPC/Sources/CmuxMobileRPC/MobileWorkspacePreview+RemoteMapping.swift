import Foundation
public import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Build a preview value from a remote workspace-list entry.
    /// - Parameter remote: A workspace decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Workspace) {
        self.init(
            id: ID(rawValue: remote.id),
            windowID: remote.windowID,
            name: remote.title,
            customDescription: remote.customDescription,
            customDescriptionIsTruncated: remote.customDescriptionIsTruncated ?? false,
            customColorHex: remote.customColorHex,
            currentDirectory: remote.currentDirectory,
            isPinned: remote.isPinned ?? false,
            groupID: remote.groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
            previewText: remote.preview,
            previewAt: remote.previewAt.map { Date(timeIntervalSince1970: $0) },
            lastActivityAt: remote.lastActivityAt.map { Date(timeIntervalSince1970: $0) },
            hasUnread: remote.hasUnread ?? false,
            unreadCount: remote.unreadCount,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            },
            surfaces: (remote.surfaces ?? []).map(MobileSurfacePreview.init(remote:)),
            simulators: remote.simulators
        )
    }
}

extension MobileSurfacePreview {
    init(remote: MobileSyncWorkspaceListResponse.Surface) {
        self.init(
            id: ID(rawValue: remote.surfaceID),
            kind: Kind(rawValue: remote.kind),
            title: remote.title,
            filePath: remote.filePath,
            todo: remote.todo,
            isFocused: remote.isFocused
        )
    }
}

extension MobileWorkspaceGroupPreview {
    /// Build a group preview value from a remote workspace-list group entry.
    /// - Parameter remote: A group decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Group) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.name,
            isCollapsed: remote.isCollapsed,
            isPinned: remote.isPinned,
            iconSymbol: remote.iconSymbol,
            anchorWorkspaceID: MobileWorkspacePreview.ID(rawValue: remote.anchorWorkspaceID)
        )
    }
}

extension MobileTerminalPreview {
    /// Build a preview value from a remote terminal entry.
    /// - Parameter remote: A terminal decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Terminal) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            currentDirectory: remote.currentDirectory,
            isReady: remote.isReady ?? true,
            isFocused: remote.isFocused
        )
    }
}
