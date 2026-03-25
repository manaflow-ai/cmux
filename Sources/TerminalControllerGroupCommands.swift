import Foundation

/// Socket API commands for workspace parent-child management.
/// In the new model, workspaces themselves are groups — a workspace with children
/// is still a clickable workspace with its own terminal.
extension TerminalController {

    // MARK: - Group Commands (workspace-as-group model)

    func v2GroupCreate(params: [String: Any]) -> V2CallResult {
        // In the new model, "creating a group" means creating a parent workspace.
        // The workspace is a normal workspace that can have children added to it.
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            let ws = tm.addWorkspace(select: false)
            if let title = params["title"] as? String {
                ws.title = title
            }
            if let color = params["color"] as? String {
                ws.customColor = color
            }
            return .ok(["workspace_id": ws.id.uuidString])
        }
    }

    func v2GroupList(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            let tree = tm.items.compactMap { wsId -> [String: Any]? in
                guard let ws = tm.workspace(for: wsId) else { return nil }
                return serializeWorkspaceTree(ws, tabManager: tm)
            }
            return .ok(["workspaces": tree])
        }
    }

    func v2GroupDelete(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let ws = tm.workspace(for: wsId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }
            tm.closeWorkspace(ws)
            return .ok(["deleted": true])
        }
    }

    func v2GroupCollapse(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let ws = tm.workspace(for: wsId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }
            ws.isCollapsed = true
            tm.items = tm.groupManager.items
            return .ok(["collapsed": true])
        }
    }

    func v2GroupExpand(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let ws = tm.workspace(for: wsId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }
            ws.isCollapsed = false
            tm.items = tm.groupManager.items
            return .ok(["expanded": true])
        }
    }

    func v2GroupRename(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        guard let title = params["title"] as? String else {
            return .err(code: "missing_param", message: "Missing 'title'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let ws = tm.workspace(for: wsId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }
            ws.title = title
            return .ok(["renamed": true])
        }
    }

    func v2GroupSetColor(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["group_id"] as? String ?? params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'workspace_id'", data: nil)
        }
        let color = params["color"] as? String
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let ws = tm.workspace(for: wsId) else {
                return V2CallResult.err(code: "not_found", message: "Workspace not found", data: nil)
            }
            ws.customColor = color
            return .ok(["color_set": true])
        }
    }

    func v2GroupAddWorkspace(params: [String: Any]) -> V2CallResult {
        guard let parentIdStr = params["group_id"] as? String ?? params["parent_id"] as? String,
              let parentId = UUID(uuidString: parentIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'group_id'/'parent_id'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            guard let child = tm.addChildWorkspace(for: parentId) else {
                return V2CallResult.err(code: "max_depth", message: "Cannot add child (max depth 3)", data: nil)
            }
            return .ok(["workspace_id": child.id.uuidString])
        }
    }

    func v2GroupRemoveWorkspace(params: [String: Any]) -> V2CallResult {
        guard let wsIdStr = params["workspace_id"] as? String,
              let wsId = UUID(uuidString: wsIdStr) else {
            return .err(code: "missing_param", message: "Missing or invalid 'workspace_id'", data: nil)
        }
        return v2MainSync {
            guard let tm = v2ResolveTabManager(params: params) else {
                return V2CallResult.err(code: "no_window", message: "No window found", data: nil)
            }
            // Remove from parent's children and promote to top-level
            if let parent = tm.groupManager.parentWorkspace(of: wsId) {
                tm.groupManager.removeChildId(wsId, from: parent.id)
                tm.groupManager.registerWorkspaceAsStandalone(wsId)
                tm.items = tm.groupManager.items
            }
            return .ok(["removed": true])
        }
    }

    // MARK: - Serialization

    private func serializeWorkspaceTree(
        _ ws: Workspace, tabManager: TabManager
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": ws.id.uuidString,
            "title": ws.title,
            "working_directory": ws.currentDirectory,
            "is_collapsed": ws.isCollapsed,
            "has_children": ws.hasChildren
        ]
        if let color = ws.customColor { result["color"] = color }
        if ws.hasChildren {
            result["children"] = ws.childWorkspaceIds.compactMap { childId -> [String: Any]? in
                guard let child = tabManager.workspace(for: childId) else { return nil }
                return serializeWorkspaceTree(child, tabManager: tabManager)
            }
        }
        return result
    }
}
