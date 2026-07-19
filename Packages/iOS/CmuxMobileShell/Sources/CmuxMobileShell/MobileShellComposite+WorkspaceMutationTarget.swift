import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Returns the live client that owns a workspace row in the aggregated list.
    func workspaceMutationTarget(for id: MobileWorkspacePreview.ID) -> WorkspaceMutationTarget {
        let owner = workspaces.first(where: { $0.id == id })?.macDeviceID
        if owner == nil || owner == foregroundMacDeviceID || owner == Self.foregroundAnonymousKey {
            return WorkspaceMutationTarget(
                client: remoteClient,
                route: activeRoute,
                connectionGeneration: connectionGeneration,
                isForeground: true,
                macDeviceID: foregroundMacDeviceID
            )
        }
        if let owner, let subscription = secondaryMacSubscriptions[owner] {
            return WorkspaceMutationTarget(
                client: subscription.client,
                route: subscription.route,
                connectionGeneration: nil,
                isForeground: false,
                macDeviceID: owner
            )
        }
        return WorkspaceMutationTarget(
            client: nil,
            route: nil,
            connectionGeneration: nil,
            isForeground: false,
            macDeviceID: owner
        )
    }
}
