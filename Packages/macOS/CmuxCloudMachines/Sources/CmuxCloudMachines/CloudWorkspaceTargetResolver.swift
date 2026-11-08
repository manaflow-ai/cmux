/// Resolves a Cloud target using the window's last selection and the sidebar's order.
public struct CloudWorkspaceTargetResolver: Sendable {
    /// Creates a resolver with no persistence or independent ordering policy.
    public init() {}

    /// Selects the remembered machine when valid, otherwise the first available sidebar machine.
    /// - Parameters:
    ///   - lastSelection: A selection whose local workspace still exists in the originating window.
    ///   - currentScopeID: The currently authenticated account/team.
    ///   - sidebarMachineIDs: Available machine identities in right-sidebar presentation order.
    /// - Returns: An existing Cloud machine, or nil when signed out or the fleet is empty.
    public func resolve(
        lastSelection: CloudWorkspaceSelection?,
        currentScopeID: String?,
        sidebarMachineIDs: [String]
    ) -> String? {
        guard let currentScopeID, !currentScopeID.isEmpty else { return nil }
        if let lastSelection, lastSelection.scopeID == currentScopeID,
           sidebarMachineIDs.contains(lastSelection.machineID) {
            return lastSelection.machineID
        }
        return sidebarMachineIDs.first
    }
}
