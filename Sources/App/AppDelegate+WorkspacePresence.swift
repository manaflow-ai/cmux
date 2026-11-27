import CmuxAuthRuntime

extension AppDelegate {
    func configureWorkspacePresence(auth: AuthCoordinator) {
        PresenceHeartbeatClient.shared.configure(auth: auth)
        workspacePresenceController.configure(auth: auth)
    }
}
