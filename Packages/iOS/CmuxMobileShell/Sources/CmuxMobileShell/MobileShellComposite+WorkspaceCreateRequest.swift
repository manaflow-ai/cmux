internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Create a workspace and surface success/failure to the caller.
    /// - Parameter groupID: Optional destination group for the new workspace.
    /// - Parameter spec: Optional workspace-create parameters for task creation.
    /// - Returns: `success` when the connected Mac created the workspace,
    ///   otherwise the failure the UI should surface.
    @discardableResult
    public func createWorkspaceRequest(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil,
        spec: MobileWorkspaceCreateSpec? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard remoteClient != nil else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        guard groupID == nil || allowsMacScopedWorkspaceMutations(targetClient: remoteClient) else {
            return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
        }
        if let createWorkspaceTask {
            guard spec == nil, createWorkspaceTaskSpec == nil, createWorkspaceTaskGroupID == groupID else {
                return .failure(.busy(hostDisplayName: connectedHostName))
            }
            return await createWorkspaceTask.value
        }
        let taskID = UUID()
        createWorkspaceTaskID = taskID
        let task = Task<Result<Void, MobileWorkspaceMutationFailure>, Never> { @MainActor [weak self] in
            defer { self?.clearCreateWorkspaceTask(id: taskID) }
            guard let self else { return .success(()) }
            return await self.createRemoteWorkspace(
                inGroup: groupID,
                appliesOperationalError: false,
                spec: spec
            )
        }
        createWorkspaceTask = task
        createWorkspaceTaskGroupID = groupID
        createWorkspaceTaskSpec = spec
        return await task.value
    }

    func createRemoteWorkspace(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil,
        appliesOperationalError: Bool = true,
        spec: MobileWorkspaceCreateSpec? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard let client = remoteClient else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        guard groupID == nil || allowsMacScopedWorkspaceMutations(targetClient: client) else {
            return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
        }
        let generation = connectionGeneration
        do {
            var params: [String: Any] = [:]
            if let groupID {
                params["group_id"] = groupID.rawValue
            }
            if let title = spec?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                params["title"] = title
            }
            if let workingDirectory = spec?.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workingDirectory.isEmpty {
                params["working_directory"] = workingDirectory
            }
            if let initialCommand = spec?.initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !initialCommand.isEmpty {
                params["initial_command"] = initialCommand
            }
            if let initialEnv = spec?.initialEnv, !initialEnv.isEmpty {
                params["initial_env"] = initialEnv
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
            // The caller cancelled (e.g. the composer sheet was dismissed): the
            // result is dropped anyway, so don't fabricate a failure.
            guard !Task.isCancelled else { return .success(()) }
            // A stale operation (connection replaced mid-flight) must not mutate
            // the NEW connection's state, but it must still report failure:
            // mapping it to success lets the task composer dismiss and persist
            // last-used defaults for a workspace that was never created.
            if generation == connectionGeneration {
                if disconnectForAuthorizationFailureIfNeeded(error) {
                    return .failure(.authorizationFailed(hostDisplayName: connectedHostName))
                }
                markMacConnectionUnavailableIfNeeded(after: error)
                if appliesOperationalError {
                    applyOperationalError(error)
                }
            }
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
