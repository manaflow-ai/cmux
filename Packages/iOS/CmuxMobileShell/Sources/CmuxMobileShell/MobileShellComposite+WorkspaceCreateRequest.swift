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
        guard !Task.isCancelled else {
            return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
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
            if let initialCommand = spec?.initialCommand,
               !initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            let createdWorkspace: MobileWorkspacePreview.ID?
            if spec != nil {
                guard let createdWorkspaceID = response.createdWorkspaceID,
                      !createdWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      response.workspaces.contains(where: { $0.id == createdWorkspaceID }) else {
                    return .failure(.rejected(hostDisplayName: context.hostDisplayName))
                }
                createdWorkspace = MobileWorkspacePreview.ID(rawValue: createdWorkspaceID)
            } else {
                // Legacy workspace creates predate `created_workspace_id`. Keep
                // accepting their list response, while spec creates require the
                // exact created workspace so callers can navigate reliably.
                createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            }
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
            let isCurrentContext = isCurrentWorkspaceCreateContext(context)
            if isCurrentContext {
                handleMacAvailabilityFailureIfCurrent(
                    after: error,
                    expectedClient: context.client,
                    expectedGeneration: context.generation
                )
            }
            switch WorkspaceCreatePinnedContext.caughtErrorDisposition(
                operationID: spec?.operationID,
                error: error
            ) {
            case .preserveSuccess:
                // A legacy create has no idempotency key, so an interrupted
                // request may already have succeeded and cannot be retried
                // safely. A definite host rejection must remain a failure even
                // when cancellation races its delivery. Task-composer creates
                // have an operation ID and fail closed instead.
                return .success(())
            case .failClosed:
                return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
            case .surfaceError:
                break
            }
            // A stale operation must not mutate the replacement connection,
            // but task-composer failures must remain retryable with the same ID.
            if isCurrentContext {
                if disconnectForAuthorizationFailureIfNeeded(error) {
                    return .failure(.authorizationFailed(hostDisplayName: context.hostDisplayName))
                }
                if appliesOperationalError {
                    applyOperationalError(error)
                }
            }
            return .failure(
                workspaceMutationFailure(error, hostDisplayName: context.hostDisplayName)
            )
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
