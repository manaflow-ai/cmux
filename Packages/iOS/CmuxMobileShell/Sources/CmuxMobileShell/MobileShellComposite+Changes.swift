internal import CmuxMobileRPC
public import CmuxMobileShellModel

/// Native workspace-changes access bound to the shell's current Mac connection.
extension MobileShellComposite {
    /// Creates a changes service over the current authenticated connection.
    /// - Parameter workspaceID: The workspace row identifier to target.
    /// - Returns: A workspace-bound service, or `nil` when the shell is not connected.
    public func makeChangesService(workspaceID: MobileWorkspacePreview.ID) -> MobileChangesService? {
        guard let client = changesRPCClient() else { return nil }
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        return MobileChangesService(client: client, workspaceID: remoteWorkspaceID.rawValue)
    }

    /// The connected RPC client, for native workspace changes use only.
    private func changesRPCClient() -> MobileCoreRPCClient? {
        guard connectionState == .connected else { return nil }
        return remoteClientForWorkspaceChanges
    }
}
