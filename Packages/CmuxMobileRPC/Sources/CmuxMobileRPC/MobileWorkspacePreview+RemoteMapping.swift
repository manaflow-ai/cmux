public import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Build a preview value from a remote workspace-list entry.
    /// - Parameter remote: A workspace decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Workspace) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            isPinned: remote.isPinned ?? false,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            }
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
