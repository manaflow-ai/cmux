import Foundation

extension TerminalController {
    struct TaskCreateWorkspaceCandidate {
        let tabManager: TabManager
        let windowID: UUID?
    }

    struct TaskCreateWorkspaceResolution {
        let workspace: Workspace
        let candidate: TaskCreateWorkspaceCandidate
    }

    nonisolated static func v2ExpandedWorkingDirectory(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    // Shared workspace-create implementation: the workspace.create command moved
    // to ControlCommandCoordinator, but v2MobileWorkspaceCreate still drives
    // this body for the mobile data-plane create path.
    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]? = nil,
        idempotencyCache: WorkspaceCreateIdempotencyCache? = nil
    ) -> V2CallResult {
        let outcome = v2PrepareWorkspaceCreate(
            params: params,
            tabManager: resolvedTabManager,
            taskCreateCandidates: taskCreateCandidates,
            idempotencyCache: idempotencyCache
        )
        let preparation: WorkspaceCreatePreparation
        switch outcome {
        case let .failure(result):
            return result
        case let .existing(resolution):
            return workspaceCreateResult(
                workspace: resolution.workspace,
                windowID: resolution.candidate.windowID
            )
        case let .completed(_, operationID):
            return .err(
                code: "already_completed",
                message: "workspace.create operation already completed",
                data: ["operation_id": operationID.uuidString]
            )
        case let .ready(ready):
            preparation = ready
        }
        let workingDirectory = Self.v2ExpandedWorkingDirectory(
            v2RawString(params, "working_directory")
        )
        let execution: WorkspaceCreateExecutionPreparation
        switch v2PrepareWorkspaceCreateExecution(
            params: params,
            preparation: preparation,
            workingDirectory: workingDirectory
        ) {
        case let .failure(result):
            return result
        case let .ready(ready):
            execution = ready
        }
        return v2PerformWorkspaceCreate(
            preparation: preparation,
            execution: execution
        )
    }

    private func v2PerformWorkspaceCreate(
        preparation: WorkspaceCreatePreparation,
        execution: WorkspaceCreateExecutionPreparation,
        operationAlreadyAccepted: Bool = false
    ) -> V2CallResult {
        let tabManager = preparation.tabManager
        let operationID = preparation.operationID

        var newWorkspace: Workspace?
        if let operationID, !operationAlreadyAccepted {
            // Acceptance must be durable before addWorkspace constructs a
            // terminal and can execute the task command. A crash in between
            // intentionally favors at-most-once startup over workspace recovery.
            do {
                try preparation.idempotencyCache.accept(operationID: operationID)
            } catch {
                return .err(code: "invalid_params", message: "Invalid layout: \(error.localizedDescription)", data: nil)
            }
        }

        var newId: UUID?
        var initialSurfaceId: UUID?
        var backendRequestId: UUID?
        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        let shouldEagerLoadTerminal = v2Bool(params, "eager_load_terminal") ?? !shouldFocus
        let shouldAutoRefreshMetadata = v2Bool(params, "auto_refresh_metadata") ?? true
        if let groupId {
            let validation = v2MainSync {
                let groupExists = tabManager.workspaceGroups.contains(where: { $0.id == groupId })
                let referenceIsMember = groupReferenceWorkspaceId.map { referenceWorkspaceId in
                    tabManager.tabs.contains { $0.id == referenceWorkspaceId && $0.groupId == groupId }
                } ?? true
                return (groupExists: groupExists, referenceIsMember: referenceIsMember)
            }
            guard validation.groupExists else {
                return .err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupId.uuidString]
                )
                return .err(
                    code: "persistence_failed",
                    message: "Workspace task could not be reserved safely",
                    data: nil
                )
            }
        }
        if layoutNode != nil,
           tabManager.terminalClientComposition
            .terminalBackendTopologyMutationCoordinator != nil {
            return .err(
                code: "unavailable",
                message: "Custom layouts are not supported by the persistent terminal backend",
                data: nil
            )
        }
        v2MainSync {
            let configureWorkspace: @MainActor (Workspace) -> Void = { ws in
                ws.setCustomDescription(description)
                if let layoutNode {
                    ws.applyCustomLayout(
                        layoutNode,
                        baseCwd: cwd ?? ws.currentDirectory
                    )
                }
                if let groupId {
                    tabManager.addWorkspaceToGroup(
                        workspaceId: ws.id,
                        groupId: groupId,
                        placement: groupPlacement ?? .top,
                        referenceWorkspaceId: groupReferenceWorkspaceId
                    )
                }
            }
            let outcome = tabManager.requestAddWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
                initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
                workspaceEnvironment: workspaceEnv,
                select: shouldFocus,
                eagerLoadTerminal: shouldEagerLoadTerminal,
                autoRefreshMetadata: shouldAutoRefreshMetadata,
                onProjected: configureWorkspace
            )
            switch outcome {
            case .created(let workspace):
                configureWorkspace(workspace)
                newId = workspace.id
                initialSurfaceId = workspace.focusedPanelId
            case .submittedToBackend(let submission):
                newId = submission.workspaceID
                initialSurfaceId = submission.surfaceID
                backendRequestId = submission.requestID
            case .failed:
                break
            }
        }

        guard let newWorkspace else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "group_id": v2OrNull(groupId?.uuidString),
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupId),
            "surface_id": v2OrNull(initialSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: initialSurfaceId)
        ]
        if let backendRequestId {
            payload["pending"] = true
            payload["backend_request_id"] = backendRequestId.uuidString
            payload["status_method"] = "terminal_backend.mutation_status"
        }
        return .ok(payload)
    }

    func v2WorkspaceCloudVMOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let beforeIds = Set(tabManager.tabs.map(\.id))
        let didStart = AppDelegate.shared?.performCloudVMAction(
            tabManager: tabManager,
            debugSource: "rpc.workspace.cloud_vm_open"
        ) ?? false
        let createdWorkspace = tabManager.tabs.first { workspace in
            !beforeIds.contains(workspace.id)
                && workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading })
        }

        guard didStart || createdWorkspace != nil else {
            return .err(code: "unavailable", message: "Cloud VM action could not be started", data: nil)
        }

        let workspace = createdWorkspace ?? tabManager.selectedWorkspace
        let workspaceId = workspace?.id
        let surfaceId = workspace?.focusedPanelId
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "started": didStart,
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": v2OrNull(workspaceId?.uuidString),
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(surfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    func v2WorkspaceCloudVMTerminalReady(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawWorkspaceId = v2RawString(params, "workspace_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceId = UUID(uuidString: rawWorkspaceId) else {
            return .err(code: "invalid_params", message: "workspace_id is required", data: nil)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }
        guard let command = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .err(code: "invalid_params", message: "initial_command is required", data: ["workspace_id": workspaceId.uuidString])
        }

        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
        let outcome = workspace.requestCloudVMLoadingSurfaceTerminalReplacement(
            workspaceId: workspaceId,
            initialCommand: command,
            focus: focus
        )
        if case .failed = outcome {
            return .err(
                code: "not_found",
                message: "Cloud VM loading surface not found",
                data: ["workspace_id": workspaceId.uuidString]
            )
        }
        let panelID: UUID?
        let requestID: UUID?
        switch outcome {
        case .created(let panel):
            panelID = panel.id
            requestID = nil
        case .submittedToBackend(let submission):
            panelID = submission.surfaceID
            requestID = submission.requestID
        case .routedToRemote, .failed:
            panelID = nil
            requestID = nil
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(panelID?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: panelID),
        ]
        if let requestID {
            payload["pending"] = true
            payload["backend_request_id"] = requestID.uuidString
            payload["status_method"] = "terminal_backend.mutation_status"
        }
        return .ok(payload)
    }

    func v2MobileWorkspaceCreate(
        params: [String: Any],
        workingDirectoryValidator: WorkspaceCreateWorkingDirectoryValidator? = nil,
        tabManager resolvedTabManager: TabManager? = nil,
        idempotencyCache: WorkspaceCreateIdempotencyCache? = nil
    ) async -> V2CallResult {
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let outcome = v2PrepareWorkspaceCreate(
            params: createParams,
            tabManager: resolvedTabManager,
            taskCreateCandidates: nil,
            idempotencyCache: idempotencyCache
        )
        let preparation: WorkspaceCreatePreparation
        switch outcome {
        case let .failure(result):
            return result
        case let .existing(resolution):
            return mobileWorkspaceCreateResult(
                resolution: resolution,
                params: createParams
            )
        case let .completed(_, operationID):
            return Self.v2MobileCompletedOperationResult(operationID: operationID)
        case let .ready(ready):
            preparation = ready
        }
        guard !Task.isCancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let rawWorkingDirectory: String?
        let isWorkingDirectoryProvided: Bool
        if v2HasNonNullParam(createParams, "working_directory") {
            rawWorkingDirectory = v2RawString(createParams, "working_directory")
            isWorkingDirectoryProvided = true
        } else if v2HasNonNullParam(createParams, "cwd") {
            guard let cwd = v2RawString(createParams, "cwd") else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            rawWorkingDirectory = cwd
            isWorkingDirectoryProvided = true
        } else {
            rawWorkingDirectory = nil
            isWorkingDirectoryProvided = false
        }
        let validator = workingDirectoryValidator ?? Self.v2ValidateMobileWorkingDirectory
        let validation = await validator(
            rawWorkingDirectory,
            isWorkingDirectoryProvided
        )
        guard !Task.isCancelled, validation != .cancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let workingDirectory: String?
        switch validation {
        case .notProvided:
            workingDirectory = nil
        case let .valid(path):
            workingDirectory = path
        case .invalid:
            return Self.v2InvalidWorkingDirectoryResult
        case .busy:
            return .err(
                code: "busy",
                message: "working_directory validation is busy",
                data: ["field": "working_directory"]
            )
        case .timedOut:
            return .err(
                code: "request_timeout",
                message: "working_directory validation timed out",
                data: ["field": "working_directory"]
            )
        case .cancelled:
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let execution: WorkspaceCreateExecutionPreparation
        switch v2PrepareWorkspaceCreateExecution(
            params: createParams,
            preparation: preparation,
            workingDirectory: workingDirectory
        ) {
        case let .failure(result):
            return result
        case let .ready(ready):
            execution = ready
        }
        var operationAlreadyAccepted = false
        switch await v2ReserveMobileWorkspaceCreate(preparation: preparation) {
        case .notRequired:
            break
        case .accepted:
            operationAlreadyAccepted = true
        case let .live(resolution):
            return mobileWorkspaceCreateResult(resolution: resolution, params: createParams)
        case let .failure(result):
            return result
        }
        let createResult = v2PerformWorkspaceCreate(
            preparation: preparation,
            execution: execution,
            operationAlreadyAccepted: operationAlreadyAccepted
        )
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which watches TabManager.tabsPublisher directly. Don't fire here.
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: preparation.tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }

    private func mobileWorkspaceCreateResult(
        resolution: TaskCreateWorkspaceResolution,
        params: [String: Any]
    ) -> V2CallResult {
        let workspaceID = resolution.workspace.id.uuidString
        var listParams = params
        listParams["workspace_id"] = workspaceID
        return v2MobileWorkspaceList(
            params: listParams,
            tabManager: resolution.candidate.tabManager,
            createdWorkspaceID: workspaceID
        )
    }
}
