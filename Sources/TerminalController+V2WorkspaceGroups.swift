import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 workspace group methods
extension TerminalController {
    @MainActor
    private func v2WorkspaceGroupPayload(_ group: WorkspaceGroup, tabManager: TabManager) -> [String: Any] {
        let memberIds = tabManager.tabs.compactMap { $0.groupId == group.id ? $0.id : nil }
        return [
            "id": group.id.uuidString,
            "ref": v2Ref(kind: .workspaceGroup, uuid: group.id),
            "name": group.name,
            "is_collapsed": group.isCollapsed,
            "is_pinned": group.isPinned,
            "anchor_workspace_id": group.anchorWorkspaceId.uuidString,
            "anchor_workspace_ref": v2Ref(kind: .workspace, uuid: group.anchorWorkspaceId),
            "custom_color": v2OrNull(group.customColor),
            "icon_symbol": v2OrNull(group.iconSymbol),
            "member_workspace_ids": memberIds.map { $0.uuidString },
            "member_workspace_refs": memberIds.map { v2Ref(kind: .workspace, uuid: $0) },
            "member_count": memberIds.count
        ]
    }

    func v2WorkspaceGroupList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var groups: [[String: Any]] = []
        v2MainSync {
            groups = tabManager.workspaceGroups.map { v2WorkspaceGroupPayload($0, tabManager: tabManager) }
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "groups": groups
        ])
    }

    func v2WorkspaceGroupCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let name = (params["name"] as? String) ?? ""
        let cwd = params["cwd"] as? String
        // child_workspace_ids accepts raw UUID strings AND v2 handle refs
        // (workspace:1, ws:1, etc.) so callers can use whatever they got back
        // from workspace.list / workspace-group list.
        //
        // Default behavior when the param is absent (e.g. `cmux workspace-group
        // create --name foo` from a cmux terminal): group the active sidebar
        // selection, or fall back to the caller workspace_id, or the focused
        // workspace. An empty array (explicit `--from ""`) still creates an
        // anchor-only group.
        let rawChildren: [String]
        let childrenExplicit: Bool
        if let provided = params["child_workspace_ids"] as? [String] {
            rawChildren = provided
            childrenExplicit = true
        } else if params["child_workspace_ids"] != nil,
                  !(params["child_workspace_ids"] is NSNull) {
            // Reject malformed shapes (single string, mixed array, etc.) so
            // a typo in a script doesn't silently apply the create to the
            // current sidebar selection. Empty/absent → fall through.
            return .err(
                code: "invalid_params",
                message: "child_workspace_ids must be an array of workspace handles",
                data: ["child_workspace_ids": String(describing: params["child_workspace_ids"] ?? "")]
            )
        } else {
            let fallbackIds: [UUID] = v2MainSync {
                let selected = tabManager.sidebarSelectedWorkspaceIds
                if !selected.isEmpty {
                    return tabManager.tabs.compactMap { selected.contains($0.id) ? $0.id : nil }
                }
                if let callerId = v2UUID(params, "workspace_id"),
                   tabManager.tabs.contains(where: { $0.id == callerId }) {
                    return [callerId]
                }
                if let selectedId = tabManager.selectedTabId {
                    return [selectedId]
                }
                return []
            }
            rawChildren = fallbackIds.map { $0.uuidString }
            childrenExplicit = false
        }
        var unresolved: [String] = []
        let parsedChildIds: [UUID] = rawChildren.compactMap { raw -> UUID? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let uuid = v2UUIDAny(trimmed) {
                return uuid
            }
            unresolved.append(trimmed)
            return nil
        }
        if !unresolved.isEmpty {
            return .err(
                code: "invalid_params",
                message: "Unresolved child workspace handles: \(unresolved.joined(separator: ", "))",
                data: ["unresolved": unresolved]
            )
        }
        // A syntactically valid UUID can still reference a workspace that
        // doesn't exist in this TabManager (typo, stale snapshot from a
        // closed window). Surface those explicitly instead of letting
        // createWorkspaceGroup silently drop them and produce an
        // anchor-only group.
        let knownTabIds: Set<UUID> = v2MainSync { Set(tabManager.tabs.map(\.id)) }
        let missing: [String] = parsedChildIds.compactMap { id in
            knownTabIds.contains(id) ? nil : id.uuidString
        }
        if !missing.isEmpty {
            return .err(
                code: "not_found",
                message: "Child workspace not found in target window: \(missing.joined(separator: ", "))",
                data: ["unknown_workspace_ids": missing]
            )
        }
        let childIds = parsedChildIds
        // When the caller explicitly listed children, refuse to create an
        // anchor-only group if every one of them was already an anchor of
        // another group. The keyboard-shortcut path
        // already enforces this; the socket/CLI path used to return OK with
        // a fresh empty group, hiding the real failure.
        if childrenExplicit, !parsedChildIds.isEmpty {
            let ineligible: [String] = v2MainSync {
                let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
                return parsedChildIds.compactMap { id -> String? in
                    guard tabManager.tabs.contains(where: { $0.id == id }) else { return nil }
                    if existingAnchorIds.contains(id) {
                        return id.uuidString
                    }
                    return nil
                }
            }
            if ineligible.count == parsedChildIds.count {
                return .err(
                    code: "invalid_state",
                    message: String(
                        localized: "workspaceGroup.error.allChildrenAreAnchors",
                        defaultValue: "All requested children are ineligible because they are already group anchors; ungroup them first"
                    ),
                    data: ["ineligible_workspace_ids": ineligible]
                )
            }
        }
        // workspace.group.create is NOT a focus-intent method. The select
        // option used to be honored here, but the socket focus policy says
        // non-focus commands must not change the user's active workspace.
        // Callers that want to focus the new anchor should call
        // workspace.group.focus afterward (which IS focus-intent).
        var createdGroupId: UUID?
        v2MainSync {
            createdGroupId = tabManager.createWorkspaceGroup(
                name: name,
                childWorkspaceIds: childIds,
                anchorWorkingDirectory: cwd,
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        }
        guard let gid = createdGroupId,
              let group = v2MainSync({ tabManager.workspaceGroups.first(where: { $0.id == gid }) }) else {
            return .err(code: "not_created", message: "Group was not created", data: nil)
        }
        return .ok([
            "group": v2MainSync { v2WorkspaceGroupPayload(group, tabManager: tabManager) }
        ])
    }

    func v2WorkspaceGroupUngroup(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        var found = false
        v2MainSync {
            found = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if found {
                tabManager.ungroupWorkspaceGroup(groupId: gid)
            }
        }
        guard found else {
            return .err(code: "not_found", message: "Group not found", data: [
                "group_id": gid.uuidString
            ])
        }
        return .ok(["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupDelete(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        var found = false
        var closedCount = 0
        v2MainSync {
            found = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if found {
                closedCount = tabManager.deleteWorkspaceGroup(groupId: gid)
            }
        }
        guard found else {
            return .err(code: "not_found", message: "Group not found", data: [
                "group_id": gid.uuidString
            ])
        }
        return .ok([
            "group_id": gid.uuidString,
            "closed_workspace_count": closedCount,
        ])
    }

    func v2WorkspaceGroupRename(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id"),
              let name = v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing group_id or name", data: nil)
        }
        var ok = false
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok { tabManager.renameWorkspaceGroup(groupId: gid, name: name) }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "name": name])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupSetCollapsed(params: [String: Any], isCollapsed: Bool) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        var ok = false
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok { tabManager.setWorkspaceGroupCollapsed(groupId: gid, isCollapsed: isCollapsed) }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "is_collapsed": isCollapsed])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupSetPinned(params: [String: Any], isPinned: Bool) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        var ok = false
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok { tabManager.setWorkspaceGroupPinned(groupId: gid, isPinned: isPinned) }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "is_pinned": isPinned])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupAdd(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id"),
              let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing group_id or workspace_id", data: nil)
        }
        var failureCode = "not_found"
        var failureMessage = "Group or workspace not found"
        var ok = false
        v2MainSync {
            let hasGroup = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            guard let tab = tabManager.tabs.first(where: { $0.id == wsId }), hasGroup else {
                return
            }
            // addWorkspaceToGroup silently no-ops for anchors of other
            // groups. Confirm membership actually changed before reporting
            // success so scripts don't get OK on a no-op.
            tabManager.addWorkspaceToGroup(workspaceId: wsId, groupId: gid)
            if tab.groupId == gid {
                ok = true
            } else {
                if tabManager.workspaceGroups.contains(where: { $0.id != gid && $0.anchorWorkspaceId == wsId }) {
                    failureCode = "invalid_state"
                    failureMessage = String(
                        localized: "workspaceGroup.error.workspaceIsOtherGroupAnchor",
                        defaultValue: "Workspace is the anchor of another group; ungroup it first"
                    )
                }
            }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "workspace_id": wsId.uuidString])
            : .err(code: failureCode, message: failureMessage, data: [
                "group_id": gid.uuidString,
                "workspace_id": wsId.uuidString
            ])
    }

    func v2WorkspaceGroupRemove(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        var ok = false
        v2MainSync {
            if let tab = tabManager.tabs.first(where: { $0.id == wsId }), tab.groupId != nil {
                tabManager.removeWorkspaceFromGroup(workspaceId: wsId)
                ok = true
            }
        }
        return ok
            ? .ok(["workspace_id": wsId.uuidString])
            : .err(code: "not_found", message: "Workspace not in a group", data: ["workspace_id": wsId.uuidString])
    }

    func v2WorkspaceGroupSetAnchor(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id"),
              let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing group_id or workspace_id", data: nil)
        }
        var ok = false
        v2MainSync {
            let hasGroup = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            let hasWs = tabManager.tabs.contains(where: { $0.id == wsId && $0.groupId == gid })
            if hasGroup && hasWs {
                tabManager.setWorkspaceGroupAnchor(groupId: gid, workspaceId: wsId)
                ok = true
            }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "anchor_workspace_id": wsId.uuidString])
            : .err(code: "not_found", message: "Group not found or workspace not a member", data: [
                "group_id": gid.uuidString,
                "workspace_id": wsId.uuidString
            ])
    }

    func v2WorkspaceGroupNewWorkspace(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        // workspace.group.new_workspace is NOT a focus-intent method. The
        // socket focus policy says non-focus commands must not change the
        // user's active workspace; callers that want to focus the new
        // workspace should call workspace.select / workspace.group.focus
        // afterward.
        //
        // Placement resolution: explicit `placement` param wins, then the
        // group's per-cwd `newWorkspacePlacement` from cmux.json, then the
        // global default. The CLI exposes this as
        // `cmux workspace-group new-workspace <group> --placement <afterCurrent|top|end>`.
        let placementRaw = v2String(params, "placement")
        let explicitPlacement = WorkspaceGroupNewPlacement(rawString: placementRaw)
        if let raw = placementRaw,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           explicitPlacement == nil {
            return .err(
                code: "invalid_params",
                message: "placement must be one of: afterCurrent, top, end",
                data: ["placement": raw]
            )
        }
        var createdId: UUID?
        v2MainSync {
            guard let group = tabManager.workspaceGroups.first(where: { $0.id == gid }) else { return }
            let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
            let configStore = AppDelegate.shared?.mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.cmuxConfigStore
            let configured = configStore?.resolveWorkspaceGroupConfig(forCwd: anchorCwd)?.newWorkspacePlacement
            let placement = explicitPlacement
                ?? configured
                ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
            if let newWs = tabManager.createWorkspaceInGroup(
                groupId: gid,
                placement: placement,
                select: false
            ) {
                createdId = newWs.id
            }
        }
        guard let createdId else {
            return .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
        }
        return .ok([
            "group_id": gid.uuidString,
            "workspace_id": createdId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: createdId)
        ])
    }

    func v2WorkspaceGroupSetColor(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        // Accept "hex": null to clear the override, or omit it entirely.
        let hex: String? = (params["hex"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized: String? = (hex?.isEmpty == false) ? hex : nil
        var ok = false
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok { tabManager.setWorkspaceGroupColor(groupId: gid, hex: normalized) }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "custom_color": v2OrNull(normalized)])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupSetIcon(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let symbol: String? = (params["symbol"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized: String? = (symbol?.isEmpty == false) ? symbol : nil
        var ok = false
        var storedIconSymbol: String?
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok {
                storedIconSymbol = tabManager.setWorkspaceGroupIcon(groupId: gid, symbol: normalized)
            }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "icon_symbol": v2OrNull(storedIconSymbol)])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupMove(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        // Resolve target via explicit absolute index OR relative position to
        // another group via `before_group_id` / `after_group_id`.
        var ok = false
        v2MainSync {
            guard let current = tabManager.workspaceGroups.firstIndex(where: { $0.id == gid }) else { return }
            // moveWorkspaceGroup interprets toIndex as the FINAL position the
            // group should occupy. before/after refer to a peer's CURRENT
            // index, so when the source comes before the peer in the original
            // order, removing the source shifts the peer left by one, and the
            // translated final position must shift with it.
            let target: Int? = {
                if let toIndex = v2Int(params, "to_index") {
                    return toIndex
                }
                if let beforeId = v2UUID(params, "before_group_id"),
                   let beforeIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == beforeId }) {
                    return current < beforeIndex ? beforeIndex - 1 : beforeIndex
                }
                if let afterId = v2UUID(params, "after_group_id"),
                   let afterIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == afterId }) {
                    return current < afterIndex ? afterIndex : afterIndex + 1
                }
                return nil
            }()
            guard let target else { return }
            tabManager.moveWorkspaceGroup(groupId: gid, toIndex: target)
            ok = true
        }
        return ok
            ? .ok(["group_id": gid.uuidString])
            : .err(code: "invalid_params", message: "Missing or unresolvable target position", data: ["group_id": gid.uuidString])
    }

    func v2WorkspaceGroupFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        var anchorId: UUID?
        v2MainSync {
            guard let group = tabManager.workspaceGroups.first(where: { $0.id == gid }),
                  let anchor = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId }) else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            // Route through selectWorkspace so the explicit-resume
            // notification dismissal and other selection side effects fire,
            // matching workspace.select and the sidebar header click path.
            tabManager.selectWorkspace(anchor)
            anchorId = anchor.id
        }
        guard let anchorId else {
            return .err(code: "not_found", message: "Group or anchor not found", data: ["group_id": gid.uuidString])
        }
        return .ok([
            "group_id": gid.uuidString,
            "anchor_workspace_id": anchorId.uuidString,
            "anchor_workspace_ref": v2Ref(kind: .workspace, uuid: anchorId)
        ])
    }

}
