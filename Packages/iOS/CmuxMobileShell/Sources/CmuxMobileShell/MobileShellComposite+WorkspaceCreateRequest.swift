internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Create a workspace and surface success/failure to the caller.
    /// - Parameter groupID: Optional destination group for the new workspace.
    /// - Returns: `success` when the workspace was created (or the local preview
    ///   path synthesized one), otherwise the failure the UI should surface.
    @discardableResult
    public func createWorkspaceRequest(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard remoteClient != nil else {
            return createWorkspace(inGroup: groupID)
        }
        if let createWorkspaceTask {
            return await createWorkspaceTask.value
        }
        let taskID = UUID()
        createWorkspaceTaskID = taskID
        let task = Task<Result<Void, MobileWorkspaceMutationFailure>, Never> { @MainActor [weak self] in
            defer { self?.clearCreateWorkspaceTask(id: taskID) }
            guard let self else { return .success(()) }
            return await self.createRemoteWorkspace(inGroup: groupID)
        }
        createWorkspaceTask = task
        return await task.value
    }

    func createRemoteWorkspace(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard let client = remoteClient else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        let generation = connectionGeneration
        do {
            var params: [String: Any] = [:]
            if let groupID {
                params["group_id"] = groupID.rawValue
            }
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create", params: params)
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation), !Task.isCancelled else {
                return .success(())
            }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            let createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            if let createdWorkspace {
                setSelectedWorkspaceID(
                    rowWorkspaceID(
                        forRemoteWorkspaceID: createdWorkspace,
                        macDeviceID: foregroundMacDeviceID
                    ) ?? createdWorkspace
                )
            }
            syncSelectedTerminalForWorkspace()
            if createdWorkspace != nil {
                // A "+" actually created and selected a new workspace, so its terminal is freshly created.
                suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
            }
            return .success(())
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return .success(()) }
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
            }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
            if let connectionError = error as? MobileShellConnectionError {
                switch connectionError {
                case .connectionClosed:
                    return .failure(.notConnected(hostDisplayName: connectedHostName))
                case .requestTimedOut:
                    return .failure(.requestTimedOut(hostDisplayName: connectedHostName))
                case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
                    return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
                case let .rpcError(code, _):
                    let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let normalizedCode,
                       ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required", "account_mismatch"].contains(normalizedCode) {
                        return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
                    }
                    if normalizedCode == "unavailable" {
                        return .failure(.notConnected(hostDisplayName: connectedHostName))
                    }
                    return .failure(.rejected(hostDisplayName: connectedHostName))
                case .invalidResponse:
                    return .failure(.rejected(hostDisplayName: connectedHostName))
                }
            }
            return .failure(.rejected(hostDisplayName: connectedHostName))
        }
    }
}
