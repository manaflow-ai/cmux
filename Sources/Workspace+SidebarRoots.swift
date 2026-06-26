extension Workspace {
    var shouldUseRemoteWorkspaceRootForSidebars: Bool {
        guard let remoteConfiguration else { return false }
        if remoteConfiguration.preserveAfterTerminalExit {
            return true
        }
        if activeRemoteTerminalSessionCount > 0 {
            return true
        }
        return remoteConnectionState != .disconnected
    }
}
