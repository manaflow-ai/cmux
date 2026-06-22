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
            isPinned: remote.isPinned ?? false,
            groupID: remote.groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
            previewText: remote.preview,
            previewAt: remote.previewAt.map { Date(timeIntervalSince1970: $0) },
            lastActivityAt: remote.lastActivityAt.map { Date(timeIntervalSince1970: $0) },
            hasUnread: remote.hasUnread ?? false,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            }
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
            parentGroupID: remote.parentGroupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
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
            isReady: remote.isReady ?? true,
            isFocused: remote.isFocused
        )
    }
}
