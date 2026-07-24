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
        if mobileWorkspaceMoveHasInvalidGroupID(params: params) {
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
        if v2HasNonNullParam(params, "move_group"), v2Bool(params, "move_group") == nil {
            return .err(code: "invalid_params", message: "move_group must be a boolean", data: nil)
        }
        let moveGroup = v2Bool(params, "move_group") ?? false
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

            if moveGroup {
                guard tabManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == workspaceID }) else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: "Workspace is not a group anchor",
                        data: ["workspace_id": workspaceID.uuidString]
                    )
                    return
                }
                if targetGroupID != nil {
                    mutationError = .err(
                        code: "invalid_request",
                        message: "move_group cannot change group membership",
                        data: ["workspace_id": workspaceID.uuidString]
                    )
                    return
                }
                let topLevelIds = tabManager.sidebarReorderWorkspaceIds(
                    forDraggedWorkspaceId: workspaceID,
                    targetWorkspaceId: beforeWorkspaceID,
                    usesTopLevelRows: true
                )
                let targetTopLevelIndex = mobileWorkspaceMoveTopLevelTargetIndex(
                    workspaceID: workspaceID,
                    beforeWorkspaceID,
                    targetIndex: targetIndex,
                    topLevelIds: topLevelIds,
                    tabManager: tabManager
                )
                _ = tabManager.reorderSidebarWorkspace(
                    tabId: workspaceID,
                    toIndex: targetTopLevelIndex,
                    isDragOperation: true,
                    usesTopLevelRows: true
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

    private func mobileWorkspaceMoveHasInvalidGroupID(params: [String: Any]) -> Bool {
        guard v2HasNonNullParam(params, "group_id") else {
            return false
        }
        guard let rawGroupID = v2RawString(params, "group_id")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        guard !rawGroupID.isEmpty else {
            return false
        }
        return v2UUID(params, "group_id") == nil
    }

    private func mobileWorkspaceMoveTopLevelTargetIndex(
        workspaceID: UUID,
        _ beforeWorkspaceID: UUID?,
        targetIndex: Int?,
        topLevelIds: [UUID],
        tabManager: TabManager
    ) -> Int {
        guard let targetIndex else {
            let insertionPosition = mobileWorkspaceMoveTopLevelBeforeID(
                beforeWorkspaceID,
                tabManager: tabManager
            ).flatMap { topLevelIds.firstIndex(of: $0) } ?? topLevelIds.count
            guard let sourceIndex = topLevelIds.firstIndex(of: workspaceID) else {
                return insertionPosition
            }
            let clampedInsertion = max(0, min(insertionPosition, topLevelIds.count))
            let adjustedIndex = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
            return max(0, min(adjustedIndex, max(0, topLevelIds.count - 1)))
        }
        return targetIndex
    }

    private func mobileWorkspaceMoveTopLevelBeforeID(
        _ beforeWorkspaceID: UUID?,
        tabManager: TabManager
    ) -> UUID? {
        guard let beforeWorkspaceID,
              let beforeWorkspace = tabManager.tabs.first(where: { $0.id == beforeWorkspaceID }) else {
            return beforeWorkspaceID
        }
        guard let groupID = beforeWorkspace.groupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
            return beforeWorkspaceID
        }
        return group.anchorWorkspaceId
    }
}
