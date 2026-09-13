import Foundation

extension SurfaceCatalog {
    /// Captures a read precondition without I/O. It expires on a name change,
    /// projection move, daemon restart, or local restore before a callback returns.
    func cloudAgentNameContext(workspaceID: UUID, panelID: UUID) -> CloudAgentNameContext? {
        guard let projection = projection(forPanel: panelID), projection.workspaceID == workspaceID,
              cloudStateObservations[projection.resource.machine]?.freshness == .current,
              let state = cloudStates[projection.resource.machine] else { return nil }
        return CloudAgentNameContext(projection: projection, state: state)
    }

    /// nil means local/SSH: their existing title semantics continue unchanged.
    /// Cloud names are never speculative UI state; every projection waits for the
    /// same accepted graph. Errors keep that graph visible and report the refusal.
    func submitCloudPanelRename(
        workspace: Workspace, panelID: UUID, title: String?, source: Workspace.CustomTitleSource,
        context: CloudAgentNameContext? = nil
    ) -> Bool? {
        guard let projection = projection(forPanel: panelID), projection.workspaceID == workspace.id,
              !projection.resource.machine.isLocal, projection.resource.kind == .terminal else { return nil }
        let machine = projection.resource.machine
        guard let resource = resources[projection.resource],
              let tabID = cloudWorkspaceRenameService.remoteTabID(for: projection, resource: resource) else { return false }
        let name = CloudRemoteRenameName(rawValue: title ?? "").wireValue
        let key = CloudRenameCoordinator.Key.tab(machine: machine, id: tabID)
        let write: Task<Void, Error>
        if source == .auto {
            guard !name.isEmpty, let context,
                  context == cloudAgentNameContext(workspaceID: workspace.id, panelID: panelID),
                  cloudRenameCoordinator.pendingName(for: key) == nil,
                  let provider = provider(for: machine) as? any SurfaceAgentNaming else { return false }
            write = cloudRenameCoordinator.enqueue(key: key, pendingName: name) { [weak self] in
                guard let self, self.provider(for: machine) === provider,
                      context == self.cloudAgentNameContext(workspaceID: workspace.id, panelID: panelID)
                else { throw CancellationError() }
                try await provider.renameAgentTab(context: context, name: name)
            }
        } else {
            write = enqueueRemoteTabRename(on: machine, id: tabID, name: name)
        }
        observeCloudNameWrite(write, workspace: workspace, automatic: source == .auto)
        return true
    }

    func submitCloudWorkspaceRename(
        workspace: Workspace, title: String?, source: Workspace.CustomTitleSource
    ) -> Bool? {
        guard let binding = workspace.cloudVMBinding, let remoteID = binding.remoteWorkspaceID else { return nil }
        // Daemon workspaces have an explicit nonempty name. An agent callback
        // targets its terminal tab, never a local alias of this workspace.
        guard source == .user else { return false }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return false }
        let write = enqueueRemoteWorkspaceRename(on: .cloud(binding.vmID), id: remoteID, name: name)
        observeCloudNameWrite(write, workspace: workspace, automatic: false)
        return true
    }

    private func observeCloudNameWrite(_ write: Task<Void, Error>, workspace: Workspace, automatic: Bool) {
        Task { @MainActor [weak workspace] in
            do { try await write.value }
            catch {
                // A superseded automatic result is expected, not a user error.
                if !automatic, !(error is CancellationError) { workspace?.presentCloudPlacementFailure(error) }
            }
        }
    }
}
