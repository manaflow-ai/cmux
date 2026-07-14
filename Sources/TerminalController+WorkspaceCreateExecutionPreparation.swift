import CmuxSettings
import Foundation

private func sanitizedInitialEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.reduce(into: [:]) { result, pair in
        let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains("\0"),
              !key.contains("="),
              !pair.value.contains("\0") else {
            return
        }
        result[key] = pair.value
    }
}

extension TerminalController {
    struct WorkspaceCreateExecutionPreparation {
        let title: String?
        let description: String?
        let initialCommand: String?
        let initialEnvironment: [String: String]
        let workspaceEnvironment: [String: String]
        let workingDirectory: String?
        let groupID: UUID?
        let groupPlacement: WorkspaceGroupNewPlacement?
        let groupReferenceWorkspaceID: UUID?
        let layoutNode: CmuxLayoutNode?
        let shouldFocus: Bool
        let shouldEagerLoadTerminal: Bool
        let shouldAutoRefreshMetadata: Bool
    }

    enum WorkspaceCreateExecutionPreparationOutcome {
        case failure(V2CallResult)
        case ready(WorkspaceCreateExecutionPreparation)
    }

    func v2PrepareWorkspaceCreateExecution(
        params: [String: Any],
        preparation: WorkspaceCreatePreparation,
        workingDirectory: String?
    ) -> WorkspaceCreateExecutionPreparationOutcome {
        let requestedInitialCommand = v2RawString(params, "initial_command")
        let initialCommand = requestedInitialCommand.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let initialEnvironment = sanitizedInitialEnvironment(v2StringMap(params, "initial_env") ?? [:])
        let workspaceEnvironment = Workspace.sanitizedWorkspaceEnvironment(
            v2StringMap(params, "workspace_env") ?? [:]
        )
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let string = raw as? String else {
                return .failure(.err(code: "invalid_params", message: "cwd must be a string", data: nil))
            }
            cwd = Self.v2ExpandedWorkingDirectory(string)
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = requestedTitle?.isEmpty == false ? requestedTitle : nil
        let description = v2RawString(params, "description")
        let groupID = v2UUID(params, "group_id")
        if v2HasNonNullParam(params, "group_id"), groupID == nil {
            return .failure(.err(code: "invalid_params", message: "Missing or invalid group_id", data: nil))
        }
        let hasGroupPlacement = v2HasNonNullParam(params, "group_placement")
            || v2HasNonNullParam(params, "placement")
        let hasGroupReference = v2HasNonNullParam(params, "group_reference_workspace_id")
            || v2HasNonNullParam(params, "reference_workspace_id")
        if groupID == nil, hasGroupPlacement || hasGroupReference {
            return .failure(.err(
                code: "invalid_params",
                message: "group_id is required for group placement",
                data: nil
            ))
        }
        let rawGroupPlacement = v2RawString(params, "group_placement")
            ?? (groupID == nil ? nil : v2RawString(params, "placement"))
        let groupPlacement = WorkspaceGroupNewPlacement(rawString: rawGroupPlacement)
        if let rawGroupPlacement,
           !rawGroupPlacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           groupPlacement == nil {
            return .failure(.err(
                code: "invalid_params",
                message: "Invalid group_placement",
                data: ["group_placement": rawGroupPlacement]
            ))
        }
        let groupReferenceWorkspaceID: UUID?
        if v2HasNonNullParam(params, "group_reference_workspace_id") {
            guard let parsed = v2UUID(params, "group_reference_workspace_id") else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Missing or invalid group_reference_workspace_id",
                    data: nil
                ))
            }
            groupReferenceWorkspaceID = parsed
        } else if v2HasNonNullParam(params, "reference_workspace_id") {
            guard let parsed = v2UUID(params, "reference_workspace_id") else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Missing or invalid group_reference_workspace_id",
                    data: nil
                ))
            }
            groupReferenceWorkspaceID = parsed
        } else {
            groupReferenceWorkspaceID = nil
        }

        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .failure(.err(
                    code: "invalid_params",
                    message: "layout must be a valid JSON object",
                    data: nil
                ))
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .failure(.err(
                    code: "invalid_params",
                    message: "Invalid layout: \(error.localizedDescription)",
                    data: nil
                ))
            }
        }

        if let groupID {
            let validation = v2MainSync {
                let groupExists = preparation.tabManager.workspaceGroups.contains { $0.id == groupID }
                let referenceIsMember = groupReferenceWorkspaceID.map { referenceID in
                    preparation.tabManager.tabs.contains { $0.id == referenceID && $0.groupId == groupID }
                } ?? true
                return (groupExists, referenceIsMember)
            }
            guard validation.0 else {
                return .failure(.err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupID.uuidString]
                ))
            }
            guard validation.1 else {
                return .failure(.err(
                    code: "invalid_params",
                    message: controlWorkspaceGroupStrings().invalidReferenceWorkspace,
                    data: ["group_reference_workspace_id": groupReferenceWorkspaceID?.uuidString ?? ""]
                ))
            }
        }

        return .ready(WorkspaceCreateExecutionPreparation(
            title: title,
            description: description,
            initialCommand: initialCommand,
            initialEnvironment: initialEnvironment,
            workspaceEnvironment: workspaceEnvironment,
            workingDirectory: cwd,
            groupID: groupID,
            groupPlacement: groupPlacement,
            groupReferenceWorkspaceID: groupReferenceWorkspaceID,
            layoutNode: layoutNode,
            shouldFocus: v2FocusAllowed(requested: v2Bool(params, "focus") ?? false),
            shouldEagerLoadTerminal: v2Bool(params, "eager_load_terminal")
                ?? !v2FocusAllowed(requested: v2Bool(params, "focus") ?? false),
            shouldAutoRefreshMetadata: v2Bool(params, "auto_refresh_metadata") ?? true
        ))
    }
}
