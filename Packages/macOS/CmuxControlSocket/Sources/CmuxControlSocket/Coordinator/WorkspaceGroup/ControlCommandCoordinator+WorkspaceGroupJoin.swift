internal import Foundation

/// The atomic workspace-group join command.
extension ControlCommandCoordinator {
    /// `workspace.group.join` — find a group by name (or create it) and add the
    /// workspace to it. Safe to repeat: a workspace already in the group is a
    /// no-op that still returns the group.
    func workspaceGroupJoin(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = rawString(params, "name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return .err(code: "invalid_params", message: "Missing name", data: nil)
        }
        guard let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let resolution = context?.controlJoinWorkspaceGroup(
            routing: routingSelectors(params),
            name: name,
            workspaceID: wsId
        ) ?? .tabManagerUnavailable
        let identity: JSONValue = .object([
            "name": .string(name),
            "workspace_id": .string(wsId.uuidString),
        ])
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: identity)
        case .workspaceIsOtherGroupAnchor:
            return .err(code: "invalid_state", message: workspaceGroupStrings().workspaceIsOtherGroupAnchor, data: identity)
        case .notCreated:
            return .err(code: "not_created", message: "Group was not created", data: identity)
        case .joined(let group, let created, let alreadyMember):
            return .ok(.object([
                "group": workspaceGroupPayload(group),
                "workspace_id": .string(wsId.uuidString),
                "workspace_ref": ref(.workspace, wsId),
                "created": .bool(created),
                "already_member": .bool(alreadyMember),
            ]))
        }
    }

}
