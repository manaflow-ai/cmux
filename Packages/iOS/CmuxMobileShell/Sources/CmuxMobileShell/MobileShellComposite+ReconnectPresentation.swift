import Foundation

extension MobileShellComposite {
    public var shouldPreserveWorkspaceShellDuringReconnect: Bool {
        connectionState != .connected
            && hasCachedRemoteWorkspaceSnapshot
            && !connectionRequiresReauth
            && (isRecoveringConnection || isReconnectingStoredMac)
            && workspaces.contains { !$0.terminals.isEmpty }
    }
}
