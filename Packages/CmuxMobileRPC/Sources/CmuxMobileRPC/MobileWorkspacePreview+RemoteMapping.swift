public import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Build a preview value from a remote workspace-list entry, tagging it with
    /// the paired Mac it was sourced from.
    ///
    /// The source-Mac tag is what lets the aggregated all-devices list group
    /// workspaces by device and route input/replay/viewport to the correct Mac's
    /// client, so callers mapping a `workspace.list` response must pass the Mac
    /// the list came from.
    /// - Parameters:
    ///   - remote: A workspace decoded from the RPC response.
    ///   - sourceMacDeviceID: Stable identifier of the paired Mac the list came
    ///     from. Empty for synthetic/preview sources with no real device.
    ///   - sourceMacDisplayName: Human-readable name of that paired Mac.
    public init(
        remote: MobileSyncWorkspaceListResponse.Workspace,
        sourceMacDeviceID: String = "",
        sourceMacDisplayName: String = ""
    ) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            isPinned: remote.isPinned ?? false,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            },
            sourceMacDeviceID: sourceMacDeviceID,
            sourceMacDisplayName: sourceMacDisplayName
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
