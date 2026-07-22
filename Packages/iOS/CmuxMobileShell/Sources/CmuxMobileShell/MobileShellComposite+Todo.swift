internal import CmuxMobileRPC
public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Capability advertised by Macs that accept native mobile todo mutations.
    public nonisolated static let todoCapability = "todo.v1"

    /// Whether the workspace's owning Mac supports native todo mutations.
    public func supportsTodo(in workspaceID: MobileWorkspacePreview.ID) -> Bool {
        let target = workspaceMutationTarget(for: workspaceID)
        if target.isForeground {
            return supportedHostCapabilities.contains(Self.todoCapability)
        }
        guard let macID = target.macDeviceID else { return false }
        return secondaryMacSubscriptions[macID]?.supportedHostCapabilities.contains(Self.todoCapability) == true
    }

    /// Applies one todo mutation on the owning Mac and refreshes its authoritative snapshot.
    /// - Parameters:
    ///   - mutation: The mutation to apply.
    ///   - workspaceID: The aggregated mobile workspace identifier.
    /// - Throws: A connection or RPC error when the mutation cannot be applied.
    public func performTodoMutation(
        _ mutation: MobileTodoMutation,
        workspaceID: MobileWorkspacePreview.ID
    ) async throws {
        guard supportsTodo(in: workspaceID),
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            throw MobileShellConnectionError.connectionClosed
        }
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else {
            throw MobileShellConnectionError.connectionClosed
        }
        do {
            try await client.mutateTodo(mutation, workspaceID: workspace.rpcWorkspaceID.rawValue)
            await refreshAfterWorkspaceMutation(target)
        } catch {
            if target.isForeground { markMacConnectionUnavailableIfNeeded(after: error) }
            throw error
        }
    }
}
