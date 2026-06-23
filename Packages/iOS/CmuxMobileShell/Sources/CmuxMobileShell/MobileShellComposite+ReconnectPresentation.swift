import Foundation

extension MobileShellComposite {
    /// Whether the current cached workspace shell should remain visible while reconnecting.
    public var shouldPreserveWorkspaceShellDuringReconnect: Bool {
        connectionState != .connected
            && hasCachedRemoteWorkspaceSnapshot
            && !connectionRequiresReauth
            && (isRecoveringConnection || isReconnectingStoredMac)
            && workspaces.contains { !$0.terminals.isEmpty }
    }
}
