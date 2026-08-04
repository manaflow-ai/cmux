import Foundation

extension TerminalController {
    /// Mobile-gated pane-content reorder within one workspace split tree.
    func v2MobileWorkspacePaneReorder(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let orderedPaneIDStrings = params["ordered_pane_ids"] as? [String],
              !orderedPaneIDStrings.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid ordered_pane_ids", data: nil)
        }
        let orderedPaneIDs = orderedPaneIDStrings.compactMap(UUID.init(uuidString:))
        guard orderedPaneIDs.count == orderedPaneIDStrings.count,
              Set(orderedPaneIDs).count == orderedPaneIDs.count else {
            return .err(code: "invalid_params", message: "ordered_pane_ids must be unique UUIDs", data: nil)
        }
        let baseLayoutVersion = v2Int(params, "base_layout_version")
        if v2HasNonNullParam(params, "base_layout_version"), baseLayoutVersion == nil {
            return .err(code: "invalid_params", message: "base_layout_version must be an integer", data: nil)
        }
        guard let tabManager = v2ResolveMobileWorkspaceOwner(workspaceID: workspaceID, params: params) else {
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
            // Slot IDs stay stable across content reorders, so the set check alone
            // cannot see that another reorder landed after the phone captured its
            // snapshot. The phone's observed layout version is the precondition
            // that makes concurrent reorders (second phone, Mac-local drag) fail
            // closed as a conflict instead of silently permuting the wrong panes.
            if let baseLayoutVersion, workspace.paneLayoutVersion != baseLayoutVersion {
                mutationError = .err(
                    code: "conflict",
                    message: "Pane layout changed before the reorder completed",
                    data: ["workspace_id": workspaceID.uuidString]
                )
                return
            }
            let authoritativePaneIDs = workspace.spatiallyOrderedPaneIds
            guard orderedPaneIDs.count == authoritativePaneIDs.count,
                  Set(orderedPaneIDs) == Set(authoritativePaneIDs) else {
                mutationError = .err(
                    code: "conflict",
                    message: "Pane layout changed before the reorder completed",
                    data: ["workspace_id": workspaceID.uuidString]
                )
                return
            }
            guard workspace.applyMobilePaneOrder(orderedPaneIDs) else {
                mutationError = .err(
                    code: "rejected",
                    message: "Pane reorder could not be applied",
                    data: ["workspace_id": workspaceID.uuidString]
                )
                return
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "ordered_pane_ids")
        listParams.removeValue(forKey: "base_layout_version")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    /// Mobile mutations route to the workspace's owning window first: the phone's
    /// snapshot can carry a stale `window_id` after the workspace moved windows,
    /// and honoring that id would reject a valid mutation instead of reaching the
    /// owner. Falls back to the shared resolver for workspaces not found by id.
    private nonisolated func v2ResolveMobileWorkspaceOwner(
        workspaceID: UUID,
        params: [String: Any]
    ) -> TabManager? {
        if let owner = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: workspaceID) }) {
            return owner
        }
        return v2ResolveTabManager(params: params)
    }

    /// Mobile-gated workspace reorder/group move.
    func v2MobileWorkspaceMove(params: [String: Any]) -> V2CallResult {
        let hasMoveGroup = v2HasNonNullParam(params, "move_group")
        let parsedMoveGroup = v2Bool(params, "move_group")
#if DEBUG
        let moveGroupDescription = hasMoveGroup
            ? parsedMoveGroup.map(String.init) ?? "invalid"
            : "omitted"
        cmuxDebugLog(
            "mobile.move request workspace=\(v2RawString(params, "workspace_id") ?? "nil") " +
            "group=\(v2RawString(params, "group_id") ?? "nil") " +
            "before=\(v2RawString(params, "before_workspace_id") ?? "nil") " +
            "window=\(v2RawString(params, "window_id") ?? "nil") " +
            "moveGroup=\(moveGroupDescription)"
        )
#endif
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
        if hasMoveGroup, parsedMoveGroup == nil {
            return .err(code: "invalid_params", message: "move_group must be a boolean", data: nil)
        }
        let moveGroup = parsedMoveGroup ?? false
        guard let tabManager = v2ResolveMobileWorkspaceOwner(workspaceID: workspaceID, params: params) else {
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
                let applied = tabManager.reorderWorkspace(tabId: workspaceID, before: beforeWorkspaceID)
#if DEBUG
                cmuxDebugLog("mobile.move reorder(before:) applied=\(applied) workspace=\(workspaceID.uuidString.suffix(6)) before=\(beforeWorkspaceID.uuidString.suffix(6))")
#endif
            } else if let targetIndex {
                let applied = tabManager.reorderWorkspace(tabId: workspaceID, toIndex: targetIndex)
#if DEBUG
                cmuxDebugLog("mobile.move reorder(toIndex:) applied=\(applied) workspace=\(workspaceID.uuidString.suffix(6)) index=\(targetIndex)")
#endif
            } else if let targetGroupID {
                let lastMemberIndex = tabManager.tabs.lastIndex {
                    $0.id != workspaceID && $0.groupId == targetGroupID
                }
                if let lastMemberIndex {
                    let applied = tabManager.reorderWorkspace(
                        tabId: workspaceID,
                        toIndex: tabManager.tabs.index(after: lastMemberIndex)
                    )
#if DEBUG
                    cmuxDebugLog("mobile.move reorder(groupEnd) applied=\(applied) workspace=\(workspaceID.uuidString.suffix(6)) group=\(targetGroupID.uuidString.suffix(6))")
#endif
                }
            } else {
                let applied = tabManager.reorderWorkspace(tabId: workspaceID, toIndex: tabManager.tabs.endIndex)
#if DEBUG
                cmuxDebugLog("mobile.move reorder(end) applied=\(applied) workspace=\(workspaceID.uuidString.suffix(6))")
#endif
            }
        }
        if let mutationError {
#if DEBUG
            cmuxDebugLog("mobile.move REJECTED \(String(describing: mutationError))")
#endif
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
