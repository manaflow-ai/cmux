import CmuxSettings
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

    private struct WorkspaceCreatePreparation {
        let tabManager: TabManager
        let operationID: UUID?
    }

    final class WorkspaceCreateIdempotencyCache {
        private let capacity: Int
        private var workspaceIDs: [UUID: UUID] = [:]
        private var insertionOrder: [UUID] = []
        private var nextEvictionIndex = 0

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        func workspaceID(for operationID: UUID) -> UUID? {
            workspaceIDs[operationID]
        }

        func record(operationID: UUID, workspaceID: UUID) {
            if workspaceIDs.updateValue(workspaceID, forKey: operationID) != nil {
                return
            }
            if insertionOrder.count < capacity {
                insertionOrder.append(operationID)
            } else {
                let evictedID = insertionOrder[nextEvictionIndex]
                workspaceIDs.removeValue(forKey: evictedID)
                insertionOrder[nextEvictionIndex] = operationID
                nextEvictionIndex = (nextEvictionIndex + 1) % capacity
            }
        }
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
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]? = nil
    ) -> V2CallResult {
        let prepared = v2PrepareWorkspaceCreate(
            params: params,
            tabManager: resolvedTabManager,
            taskCreateCandidates: taskCreateCandidates
        )
        if let result = prepared.result { return result }
        guard let preparation = prepared.preparation else {
            return .err(code: "internal_error", message: "Workspace create preparation failed", data: nil)
        }
        guard !v2HasNonNullParam(params, "working_directory") else {
            return .err(
                code: "invalid_params",
                message: "working_directory is only supported by mobile workspace.create",
                data: ["field": "working_directory"]
            )
        }
        return v2PerformWorkspaceCreate(
            params: params,
            preparation: preparation,
            workingDirectoryValidation: .notProvided
        )
    }

    private func v2PrepareWorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager?,
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]?
    ) -> (preparation: WorkspaceCreatePreparation?, result: V2CallResult?) {
        let operationID: UUID?
        if v2HasNonNullParam(params, "operation_id") {
            guard let parsed = v2UUID(params, "operation_id") else {
                return (
                    nil,
                    .err(code: "invalid_params", message: "operation_id must be a UUID", data: nil)
                )
            }
            operationID = parsed
        } else {
            operationID = nil
        }
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return (nil, .err(code: "unavailable", message: "TabManager not available", data: nil))
        }

        if let operationID,
           let resolution = existingTaskCreateWorkspace(
               operationID: operationID,
               candidates: taskCreateCandidates ?? taskCreateWorkspaceCandidates(requested: tabManager)
           ) {
            return (
                nil,
                workspaceCreateResult(
                    workspace: resolution.workspace,
                    windowID: resolution.candidate.windowID
                )
            )
        }
        return (
            WorkspaceCreatePreparation(
                tabManager: tabManager,
                operationID: operationID
            ),
            nil
        )
    }

    private func v2PerformWorkspaceCreate(
        params: [String: Any],
        preparation: WorkspaceCreatePreparation,
        workingDirectoryValidation: WorkspaceCreateWorkingDirectoryValidation
    ) -> V2CallResult {
        let tabManager = preparation.tabManager
        let operationID = preparation.operationID

        let workingDirectory: String?
        switch workingDirectoryValidation {
        case .notProvided:
            workingDirectory = nil
        case let .valid(path):
            workingDirectory = path
        case .invalid:
            return Self.v2InvalidWorkingDirectoryResult
        case .cancelled:
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        // Persistent per-workspace environment (issue #5995): applied to the
        // initial shell and every later pane/surface/split, then round-tripped
        // through session restore.
        let workspaceEnv = Workspace.sanitizedWorkspaceEnvironment(
            v2StringMap(params, "workspace_env") ?? [:]
        )
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = Self.v2ExpandedWorkingDirectory(str)
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        let groupId = v2UUID(params, "group_id")
        if v2HasNonNullParam(params, "group_id"), groupId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let hasGroupPlacementParam = v2HasNonNullParam(params, "group_placement")
            || v2HasNonNullParam(params, "placement")
        let hasGroupReferenceParam = v2HasNonNullParam(params, "group_reference_workspace_id")
            || v2HasNonNullParam(params, "reference_workspace_id")
        if groupId == nil, hasGroupPlacementParam || hasGroupReferenceParam {
            return .err(
                code: "invalid_params",
                message: "group_id is required for group placement",
                data: nil
            )
        }
        let rawGroupPlacement = v2RawString(params, "group_placement")
            ?? (groupId == nil ? nil : v2RawString(params, "placement"))
        let groupPlacement = WorkspaceGroupNewPlacement(rawString: rawGroupPlacement)
        if let raw = rawGroupPlacement,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           groupPlacement == nil {
            return .err(code: "invalid_params", message: "Invalid group_placement", data: ["group_placement": raw])
        }
        let groupReferenceWorkspaceId: UUID?
        if v2HasNonNullParam(params, "group_reference_workspace_id") {
            guard let parsed = v2UUID(params, "group_reference_workspace_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid group_reference_workspace_id", data: nil)
            }
            groupReferenceWorkspaceId = parsed
        } else if v2HasNonNullParam(params, "reference_workspace_id") {
            guard let parsed = v2UUID(params, "reference_workspace_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid group_reference_workspace_id", data: nil)
            }
            groupReferenceWorkspaceId = parsed
        } else {
            groupReferenceWorkspaceId = nil
        }

        // Decode optional layout param (same JSON schema as cmux.json layout field).
        // Validate before creating the workspace so malformed layouts fail fast.
        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .err(code: "invalid_params", message: "layout must be a valid JSON object", data: nil)
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .err(code: "invalid_params", message: "Invalid layout: \(error.localizedDescription)", data: nil)
            }
        }

        var newWorkspace: Workspace?
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
            }
            guard validation.referenceIsMember else {
                return .err(
                    code: "invalid_params",
                    message: controlWorkspaceGroupStrings().invalidReferenceWorkspace,
                    data: ["group_reference_workspace_id": groupReferenceWorkspaceId?.uuidString ?? ""]
                )
            }
        }
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
                initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
                workspaceEnvironment: workspaceEnv,
                select: shouldFocus,
                eagerLoadTerminal: shouldEagerLoadTerminal,
                autoRefreshMetadata: shouldAutoRefreshMetadata
            )
            ws.taskCreateOperationID = operationID
            ws.setCustomDescription(description)
            if let layoutNode {
                ws.applyCustomLayout(layoutNode, baseCwd: cwd ?? ws.currentDirectory)
            }
            if let groupId {
                tabManager.addWorkspaceToGroup(
                    workspaceId: ws.id,
                    groupId: groupId,
                    placement: groupPlacement ?? .top,
                    referenceWorkspaceId: groupReferenceWorkspaceId
                )
            }
            newWorkspace = ws
        }

        guard let newWorkspace else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        if let operationID {
            workspaceCreateIdempotencyCache.record(operationID: operationID, workspaceID: newWorkspace.id)
        }
        return workspaceCreateResult(
            workspace: newWorkspace,
            windowID: v2ResolveWindowId(tabManager: tabManager)
        )
    }

    private func taskCreateWorkspaceCandidates(requested tabManager: TabManager) -> [TaskCreateWorkspaceCandidate] {
        var candidates = [TaskCreateWorkspaceCandidate(
            tabManager: tabManager,
            windowID: v2ResolveWindowId(tabManager: tabManager)
        )]
        candidates.append(contentsOf: AppDelegate.shared?.scriptableMainWindows().map {
            TaskCreateWorkspaceCandidate(tabManager: $0.tabManager, windowID: $0.windowId)
        } ?? [])
        return candidates
    }

    private func existingTaskCreateWorkspace(
        operationID: UUID,
        candidates: [TaskCreateWorkspaceCandidate]
    ) -> TaskCreateWorkspaceResolution? {
        let resolution = Self.resolveTaskCreateWorkspace(
            operationID: operationID,
            cachedWorkspaceID: workspaceCreateIdempotencyCache.workspaceID(for: operationID),
            candidates: candidates
        )
        if let resolution {
            workspaceCreateIdempotencyCache.record(
                operationID: operationID,
                workspaceID: resolution.workspace.id
            )
        }
        return resolution
    }

    static func resolveTaskCreateWorkspace(
        operationID: UUID,
        cachedWorkspaceID: UUID?,
        candidates: [TaskCreateWorkspaceCandidate]
    ) -> TaskCreateWorkspaceResolution? {
        var seen: Set<ObjectIdentifier> = []
        let uniqueCandidates = candidates.filter { seen.insert(ObjectIdentifier($0.tabManager)).inserted }
        if let cachedWorkspaceID {
            for candidate in uniqueCandidates {
                if let workspace = candidate.tabManager.tabs.first(where: { $0.id == cachedWorkspaceID }),
                   workspace.taskCreateOperationID == operationID {
                    return TaskCreateWorkspaceResolution(workspace: workspace, candidate: candidate)
                }
            }
        }
        for candidate in uniqueCandidates {
            if let workspace = candidate.tabManager.tabs.first(where: { $0.taskCreateOperationID == operationID }) {
                return TaskCreateWorkspaceResolution(workspace: workspace, candidate: candidate)
            }
        }
        return nil
    }

    private func workspaceCreateResult(
        workspace: Workspace,
        windowID: UUID?
    ) -> V2CallResult {
        let workspaceID = workspace.id
        let groupID = workspace.groupId
        let surfaceID = workspace.focusedPanelId
        return .ok([
            "window_id": v2OrNull(windowID?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowID),
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            "group_id": v2OrNull(groupID?.uuidString),
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupID),
            "surface_id": v2OrNull(surfaceID?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID)
        ])
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
        guard let panel = workspace.replaceCloudVMLoadingSurfaceWithTerminal(
            workspaceId: workspaceId,
            initialCommand: command,
            focus: focus
        ) else {
            return .err(
                code: "not_found",
                message: "Cloud VM loading surface not found",
                data: ["workspace_id": workspaceId.uuidString]
            )
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": panel.id.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
        ])
    }

    func v2MobileWorkspaceCreate(
        params: [String: Any],
        workingDirectoryValidator: WorkspaceCreateWorkingDirectoryValidator? = nil,
        tabManager resolvedTabManager: TabManager? = nil
    ) async -> V2CallResult {
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let prepared = v2PrepareWorkspaceCreate(
            params: createParams,
            tabManager: resolvedTabManager,
            taskCreateCandidates: nil
        )
        if let result = prepared.result { return result }
        guard let preparation = prepared.preparation else {
            return .err(code: "internal_error", message: "Workspace create preparation failed", data: nil)
        }
        guard !Task.isCancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let validator = workingDirectoryValidator ?? Self.v2ValidateMobileWorkingDirectory
        let validation = await validator(
            v2RawString(createParams, "working_directory"),
            v2HasNonNullParam(createParams, "working_directory")
        )
        guard !Task.isCancelled, validation != .cancelled else {
            return .err(code: "cancelled", message: "Workspace creation was cancelled", data: nil)
        }
        let createResult = v2PerformWorkspaceCreate(
            params: createParams,
            preparation: preparation,
            workingDirectoryValidation: validation
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
}
