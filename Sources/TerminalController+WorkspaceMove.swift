import Foundation

extension TerminalController {
    /// Mobile-gated workspace reorder/group move.
    func v2MobileWorkspaceMove(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let targetGroupID = mobileWorkspaceMoveGroupID(params: params)
        if v2HasNonNullParam(params, "group_id"), targetGroupID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let beforeWorkspaceID: UUID?
        if v2HasNonNullParam(params, "before_workspace_id") {
            guard let parsedBeforeWorkspaceID = v2UUID(params, "before_workspace_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid before_workspace_id", data: nil)
            }
            beforeWorkspaceID = parsedBeforeWorkspaceID
        } else {
            beforeWorkspaceID = nil
        }
        let targetIndex = v2HasNonNullParam(params, "index") ? v2Int(params, "index") : nil
        if v2HasNonNullParam(params, "index"), targetIndex == nil {
            return .err(code: "invalid_params", message: "Missing or invalid index", data: nil)
        }
        if beforeWorkspaceID != nil && targetIndex != nil {
            return .err(
                code: "invalid_params",
                message: "Specify either before_workspace_id or index, not both",
                data: nil
            )
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }

        var mutationError: V2CallResult?
        v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                mutationError = .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: ["workspace_id": workspaceID.uuidString]
                )
                return
            }
            if let targetGroupID,
               !tabManager.workspaceGroups.contains(where: { $0.id == targetGroupID }) {
                mutationError = .err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": targetGroupID.uuidString]
                )
                return
            }
            if let beforeWorkspaceID,
               !tabManager.tabs.contains(where: { $0.id == beforeWorkspaceID }) {
                mutationError = .err(
                    code: "not_found",
                    message: "Before workspace not found",
                    data: ["before_workspace_id": beforeWorkspaceID.uuidString]
                )
                return
            }

            if workspace.groupId != targetGroupID {
                if let targetGroupID {
                    tabManager.addWorkspaceToGroup(
                        workspaceId: workspaceID,
                        groupId: targetGroupID,
                        placement: .end
                    )
                    guard tabManager.tabs.first(where: { $0.id == workspaceID })?.groupId == targetGroupID else {
                        mutationError = .err(
                            code: "invalid_request",
                            message: controlWorkspaceGroupStrings().workspaceIsOtherGroupAnchor,
                            data: ["workspace_id": workspaceID.uuidString]
                        )
                        return
                    }
                } else {
                    tabManager.removeWorkspaceFromGroup(workspaceId: workspaceID)
                }
            }

            if let beforeWorkspaceID {
                _ = tabManager.reorderWorkspace(tabId: workspaceID, before: beforeWorkspaceID)
            } else if let targetIndex {
                _ = tabManager.reorderWorkspace(tabId: workspaceID, toIndex: targetIndex)
            } else if let targetGroupID {
                let lastMemberIndex = tabManager.tabs.lastIndex {
                    $0.id != workspaceID && $0.groupId == targetGroupID
                }
                if let lastMemberIndex {
                    _ = tabManager.reorderWorkspace(
                        tabId: workspaceID,
                        toIndex: tabManager.tabs.index(after: lastMemberIndex)
                    )
                }
            } else {
                _ = tabManager.reorderWorkspace(tabId: workspaceID, toIndex: tabManager.tabs.endIndex)
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "workspace_id")
        listParams.removeValue(forKey: "group_id")
        listParams.removeValue(forKey: "before_workspace_id")
        listParams.removeValue(forKey: "index")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    private func mobileWorkspaceMoveGroupID(params: [String: Any]) -> UUID? {
        guard v2HasNonNullParam(params, "group_id"),
              let rawGroupID = v2RawString(params, "group_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawGroupID.isEmpty else {
            return nil
        }
        return v2UUID(params, "group_id")
    }
}
