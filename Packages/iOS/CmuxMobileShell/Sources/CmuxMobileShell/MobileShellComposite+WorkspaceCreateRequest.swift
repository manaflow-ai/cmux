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
        guard let context = captureWorkspaceCreateContext() else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        return await createWorkspaceRequest(
            inGroup: groupID,
            spec: spec,
            pinnedContext: context
        )
    }

    func createWorkspaceRequest(
        inGroup groupID: MobileWorkspaceGroupPreview.ID? = nil,
        spec: MobileWorkspaceCreateSpec? = nil,
        pinnedContext context: WorkspaceCreatePinnedContext,
        willStartCreate: (@MainActor () -> Void)? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard groupID == nil || allowsMacScopedWorkspaceMutations(targetClient: context.client) else {
            return .failure(.authorizationFailed(hostDisplayName: context.hostDisplayName))
        }
        if let createWorkspaceTask {
            guard spec == nil, createWorkspaceTaskSpec == nil, createWorkspaceTaskGroupID == groupID else {
                return .failure(.busy(hostDisplayName: context.hostDisplayName))
            }
            return await createWorkspaceTask.value
        }
        willStartCreate?()
        let taskID = UUID()
        createWorkspaceTaskID = taskID
        let task = Task<Result<Void, MobileWorkspaceMutationFailure>, Never> { @MainActor [weak self] in
            defer { self?.clearCreateWorkspaceTask(id: taskID) }
            guard let self else { return .success(()) }
            return await self.createRemoteWorkspace(
                inGroup: groupID,
                appliesOperationalError: false,
                spec: spec,
                pinnedContext: context
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
        spec: MobileWorkspaceCreateSpec? = nil,
        pinnedContext suppliedContext: WorkspaceCreatePinnedContext? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard let context = suppliedContext ?? captureWorkspaceCreateContext() else {
            return .failure(.notConnected(hostDisplayName: connectedHostName))
        }
        let client = context.client
        guard groupID == nil || allowsMacScopedWorkspaceMutations(targetClient: client) else {
            return .failure(.authorizationFailed(hostDisplayName: context.hostDisplayName))
        }
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
            if let operationID = spec?.operationID {
                params["operation_id"] = operationID.uuidString
            }
            guard isCurrentWorkspaceCreateContext(context), !Task.isCancelled else {
                return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
            }
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.create", params: params)
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            switch WorkspaceCreatePinnedContext.postResponseDisposition(
                operationID: spec?.operationID,
                isCancelled: Task.isCancelled,
                isCurrent: isCurrentWorkspaceCreateContext(context)
            ) {
            case .preserveSuccess:
                // Creates without an idempotency key cannot be retried safely
                // after the host returns success. Preserve that decoded result
                // across cancellation or connection replacement, but do not
                // apply its now-stale workspace list to the current session.
                return .success(())
            case .failClosed:
                return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
            case .apply:
                break
            }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            let createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            if let createdWorkspace {
                setSelectedWorkspaceID(
                    rowWorkspaceID(
                        forRemoteWorkspaceID: createdWorkspace,
                        macDeviceID: context.macDeviceID
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
            if Task.isCancelled {
                return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
            }
            // A stale operation (connection replaced mid-flight) must not mutate
            // the NEW connection's state, but it must still report failure:
            // mapping it to success lets the task composer dismiss and persist
            // last-used defaults for a workspace that was never created.
            if isCurrentWorkspaceCreateContext(context) {
                if disconnectForAuthorizationFailureIfNeeded(error) {
                    return .failure(.authorizationFailed(hostDisplayName: context.hostDisplayName))
                }
                markMacConnectionUnavailableIfNeeded(after: error)
                if appliesOperationalError {
                    applyOperationalError(error)
                }
            }
            return .failure(workspaceMutationFailure(error, hostDisplayName: context.hostDisplayName))
        }
    }

    func captureWorkspaceCreateContext() -> WorkspaceCreatePinnedContext? {
        guard connectionState == .connected, let remoteClient else { return nil }
        return WorkspaceCreatePinnedContext(
            macDeviceID: foregroundMacDeviceID,
            client: remoteClient,
            generation: connectionGeneration,
            supportedHostCapabilities: supportedHostCapabilities,
            hostDisplayName: connectedHostName
        )
    }

    private func isCurrentWorkspaceCreateContext(_ context: WorkspaceCreatePinnedContext) -> Bool {
        context.isCurrent(
            macDeviceID: foregroundMacDeviceID,
            client: remoteClient,
            generation: connectionGeneration
        ) && isSignedIn && connectionState == .connected
    }
}
