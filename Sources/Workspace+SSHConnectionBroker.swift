import CmuxCore

@MainActor
extension Workspace {
    /// Releases the workspace's shared master only after its relay and daemon cleanup finishes.
    func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        let transition = remoteSessionTransitionTask
        let connectionBroker = nativeSSHConnectionBroker
        Task { @MainActor in
            await transition?.value
            connectionBroker.releaseWorkspace(configuration)
        }
    }
}
