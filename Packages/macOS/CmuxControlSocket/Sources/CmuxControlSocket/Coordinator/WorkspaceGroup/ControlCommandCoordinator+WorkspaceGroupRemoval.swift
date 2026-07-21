internal import Foundation

extension ControlCommandCoordinator {
    /// `workspace.group.ungroup` — dissolve a group, keeping its workspaces.
    func workspaceGroupUngroup(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let groupID = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let keptCount = context?.controlUngroupWorkspaceGroup(
            routing: routingSelectors(params),
            groupID: groupID
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard keptCount >= 0 else {
            return .err(code: "not_found", message: "Group not found", data: .object([
                "group_id": .string(groupID.uuidString),
            ]))
        }
        return .ok(.object([
            "group_id": .string(groupID.uuidString),
            "operation": .string("dissolved"),
            "kept_workspace_count": .int(Int64(keptCount)),
        ]))
    }

    /// `workspace.group.delete` — dissolve by default; close only with explicit intent.
    func workspaceGroupDelete(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let groupID = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let closeWorkspaces: Bool
        switch params["close_workspaces"] {
        case nil, .null:
            closeWorkspaces = false
        case .bool(let value):
            closeWorkspaces = value
        default:
            return .err(
                code: "invalid_params",
                message: workspaceGroupStrings().closeWorkspacesMustBeBoolean,
                data: nil
            )
        }
        guard closeWorkspaces else { return workspaceGroupUngroup(params) }
        guard let closedCount = context?.controlDeleteWorkspaceGroup(
            routing: routingSelectors(params),
            groupID: groupID
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard closedCount >= 0 else {
            return .err(code: "not_found", message: "Group not found", data: .object([
                "group_id": .string(groupID.uuidString),
            ]))
        }
        return .ok(.object([
            "group_id": .string(groupID.uuidString),
            "operation": .string("closed_workspaces"),
            "closed_workspace_count": .int(Int64(closedCount)),
        ]))
    }
}
