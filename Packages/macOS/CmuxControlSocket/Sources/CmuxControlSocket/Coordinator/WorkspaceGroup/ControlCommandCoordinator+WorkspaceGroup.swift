internal import Foundation

/// The workspace-group domain (`workspace.group.*`), lifted byte-faithfully from
/// the former `TerminalController.v2WorkspaceGroup*` bodies. Each payload is
/// built directly as a ``JSONValue`` (the typed twin of the legacy
/// `[String: Any]` dictionaries); the resulting Foundation object is identical,
/// so the encoded wire bytes match.
extension ControlCommandCoordinator {
    /// Dispatches the workspace-group methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through. Some
    /// methods map onto one body with a flag (collapse/expand → `setCollapsed`,
    /// pin/unpin → `setPinned`), preserving the legacy dispatch.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a workspace-group method.
    func handleWorkspaceGroup(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.group.list":
            return workspaceGroupList(request.params)
        case "workspace.group.create":
            return workspaceGroupCreate(request.params)
        case "workspace.group.ungroup":
            return workspaceGroupUngroup(request.params)
        case "workspace.group.delete":
            return workspaceGroupDelete(request.params)
        case "workspace.group.rename":
            return workspaceGroupRename(request.params)
        case "workspace.group.collapse":
            return workspaceGroupSetCollapsed(request.params, isCollapsed: true)
        case "workspace.group.expand":
            return workspaceGroupSetCollapsed(request.params, isCollapsed: false)
        case "workspace.group.pin":
            return workspaceGroupSetPinned(request.params, isPinned: true)
        case "workspace.group.unpin":
            return workspaceGroupSetPinned(request.params, isPinned: false)
        case "workspace.group.add":
            return workspaceGroupAdd(request.params)
        case "workspace.group.remove":
            return workspaceGroupRemove(request.params)
        case "workspace.group.set_anchor":
            return workspaceGroupSetAnchor(request.params)
        case "workspace.group.new_workspace":
            return workspaceGroupNewWorkspace(request.params)
        case "workspace.group.set_color":
            return workspaceGroupSetColor(request.params)
        case "workspace.group.set_icon":
            return workspaceGroupSetIcon(request.params)
        case "workspace.group.move":
            return workspaceGroupMove(request.params)
        case "workspace.group.focus":
            return workspaceGroupFocus(request.params)
        default:
            return nil
        }
    }

    // MARK: - Payload

    /// Builds one group's payload row (the legacy `v2WorkspaceGroupPayload`),
    /// minting the `workspace_group` / `workspace` refs from the snapshot ids.
    private func workspaceGroupPayload(_ group: ControlWorkspaceGroupSnapshot) -> JSONValue {
        .object([
            "id": .string(group.id.uuidString),
            "ref": ref(.workspaceGroup, group.id),
            "name": .string(group.name),
            "is_collapsed": .bool(group.isCollapsed),
            "is_pinned": .bool(group.isPinned),
            "anchor_workspace_id": .string(group.anchorWorkspaceID.uuidString),
            "anchor_workspace_ref": ref(.workspace, group.anchorWorkspaceID),
            "custom_color": orNull(group.customColor),
            "icon_symbol": orNull(group.iconSymbol),
            "member_workspace_ids": .array(group.memberWorkspaceIDs.map { .string($0.uuidString) }),
            "member_workspace_refs": .array(group.memberWorkspaceIDs.map { ref(.workspace, $0) }),
            "member_count": .int(Int64(group.memberWorkspaceIDs.count)),
        ])
    }

    // MARK: - List

    /// `workspace.group.list` — every workspace group in the resolved window.
    func workspaceGroupList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceGroupList(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .resolved(let windowID, let groups):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "groups": .array(groups.map { workspaceGroupPayload($0) }),
            ]))
        }
    }

    // MARK: - Create

    /// `workspace.group.create` — create a group from explicit/derived children.
    func workspaceGroupCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = rawString(params, "name") ?? ""
        let cwd = rawString(params, "cwd")

        // child_workspace_ids accepts raw UUID strings AND v2 handle refs
        // (workspace:1, ws:1, etc.). A `[String]` array is explicit; any other
        // present-non-null shape is rejected; absent/null falls through to the
        // app-side fallback selection.
        let rawChildren: [String]
        let childrenExplicit: Bool
        if let provided = stringArrayExact(params["child_workspace_ids"]) {
            rawChildren = provided
            childrenExplicit = true
        } else if let value = params["child_workspace_ids"], !isNull(value) {
            return .err(
                code: "invalid_params",
                message: "child_workspace_ids must be an array of workspace handles",
                data: .object([
                    "child_workspace_ids": .string(String(describing: value.foundationObject)),
                ])
            )
        } else {
            // Absent/null: let the app derive children from the active sidebar
            // selection / caller workspace / focused workspace.
            rawChildren = []
            childrenExplicit = false
        }

        var unresolved: [String] = []
        let parsedChildIDs: [UUID] = rawChildren.compactMap { raw -> UUID? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let uuid = uuidAny(.string(trimmed)) {
                return uuid
            }
            unresolved.append(trimmed)
            return nil
        }
        if !unresolved.isEmpty {
            return .err(
                code: "invalid_params",
                message: "Unresolved child workspace handles: \(unresolved.joined(separator: ", "))",
                data: .object(["unresolved": .array(unresolved.map { .string($0) })])
            )
        }

        let resolution = context?.controlCreateWorkspaceGroup(
            routing: routingSelectors(params),
            name: name,
            cwd: cwd,
            childWorkspaceIDs: parsedChildIDs,
            childrenExplicit: childrenExplicit
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .childWorkspaceNotFound(let missing):
            return .err(
                code: "not_found",
                message: "Child workspace not found in target window: \(missing.joined(separator: ", "))",
                data: .object(["unknown_workspace_ids": .array(missing.map { .string($0) })])
            )
        case .allChildrenAreAnchors(let ineligible):
            return .err(
                code: "invalid_state",
                message: workspaceGroupStrings().allChildrenAreAnchors,
                data: .object(["ineligible_workspace_ids": .array(ineligible.map { .string($0) })])
            )
        case .notCreated:
            return .err(code: "not_created", message: "Group was not created", data: nil)
        case .created(let group):
            return .ok(.object(["group": workspaceGroupPayload(group)]))
        }
    }

    // MARK: - Ungroup / Delete / Rename

    /// `workspace.group.ungroup` — dissolve a group, keeping its workspaces.
    func workspaceGroupUngroup(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let found = context?.controlUngroupWorkspaceGroup(routing: routingSelectors(params), groupID: gid) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard found else {
            return .err(code: "not_found", message: "Group not found", data: .object([
                "group_id": .string(gid.uuidString),
            ]))
        }
        return .ok(.object(["group_id": .string(gid.uuidString)]))
    }

    /// `workspace.group.delete` — delete a group and close its workspaces.
    func workspaceGroupDelete(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let closedCount = context?.controlDeleteWorkspaceGroup(routing: routingSelectors(params), groupID: gid) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard closedCount >= 0 else {
            return .err(code: "not_found", message: "Group not found", data: .object([
                "group_id": .string(gid.uuidString),
            ]))
        }
        return .ok(.object([
            "group_id": .string(gid.uuidString),
            "closed_workspace_count": .int(Int64(closedCount)),
        ]))
    }

    /// `workspace.group.rename` — rename a group.
    func workspaceGroupRename(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id"),
              let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing group_id or name", data: nil)
        }
        guard let ok = context?.controlRenameWorkspaceGroup(routing: routingSelectors(params), groupID: gid, name: name) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString), "name": .string(name)]))
            : .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
    }

    // MARK: - Collapse / Pin

    /// `workspace.group.collapse` / `.expand` — set the group's collapsed state.
    func workspaceGroupSetCollapsed(_ params: [String: JSONValue], isCollapsed: Bool) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let ok = context?.controlSetWorkspaceGroupCollapsed(
            routing: routingSelectors(params), groupID: gid, isCollapsed: isCollapsed
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString), "is_collapsed": .bool(isCollapsed)]))
            : .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
    }

    /// `workspace.group.pin` / `.unpin` — set the group's pinned state.
    func workspaceGroupSetPinned(_ params: [String: JSONValue], isPinned: Bool) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let ok = context?.controlSetWorkspaceGroupPinned(
            routing: routingSelectors(params), groupID: gid, isPinned: isPinned
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString), "is_pinned": .bool(isPinned)]))
            : .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
    }

    // MARK: - Add / Remove / Anchor

    /// `workspace.group.add` — add a workspace to a group.
    func workspaceGroupAdd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id"),
              let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing group_id or workspace_id", data: nil)
        }
        let resolution = context?.controlAddWorkspaceToGroup(
            routing: routingSelectors(params),
            groupID: gid,
            workspaceID: wsId
        ) ?? .tabManagerUnavailable
        let identity: JSONValue = .object([
            "group_id": .string(gid.uuidString),
            "workspace_id": .string(wsId.uuidString),
        ])
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .added:
            return .ok(identity)
        case .notFound:
            return .err(code: "not_found", message: "Group or workspace not found", data: identity)
        case .workspaceIsOtherGroupAnchor:
            return .err(code: "invalid_state", message: workspaceGroupStrings().workspaceIsOtherGroupAnchor, data: identity)
        }
    }

    /// `workspace.group.remove` — remove a workspace from its group.
    func workspaceGroupRemove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let ok = context?.controlRemoveWorkspaceFromGroup(routing: routingSelectors(params), workspaceID: wsId) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["workspace_id": .string(wsId.uuidString)]))
            : .err(code: "not_found", message: "Workspace not in a group", data: .object(["workspace_id": .string(wsId.uuidString)]))
    }

    /// `workspace.group.set_anchor` — set a group's anchor workspace.
    func workspaceGroupSetAnchor(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id"),
              let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing group_id or workspace_id", data: nil)
        }
        guard let ok = context?.controlSetWorkspaceGroupAnchor(
            routing: routingSelectors(params), groupID: gid, workspaceID: wsId
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString), "anchor_workspace_id": .string(wsId.uuidString)]))
            : .err(code: "not_found", message: "Group not found or workspace not a member", data: .object([
                "group_id": .string(gid.uuidString),
                "workspace_id": .string(wsId.uuidString),
            ]))
    }

    // MARK: - New workspace

    /// `workspace.group.new_workspace` — create a workspace in a group.
    func workspaceGroupNewWorkspace(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let resolution = context?.controlCreateWorkspaceInGroup(
            routing: routingSelectors(params),
            groupID: gid,
            placementRaw: string(params, "placement")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidPlacement(let raw):
            return .err(
                code: "invalid_params",
                message: "placement must be one of: afterCurrent, top, end",
                data: .object(["placement": .string(raw)])
            )
        case .notFound:
            return .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
        case .created(let workspaceID):
            return .ok(.object([
                "group_id": .string(gid.uuidString),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        }
    }

    // MARK: - Color / Icon

    /// `workspace.group.set_color` — set or clear a group's custom color.
    func workspaceGroupSetColor(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        // Accept "hex": null to clear the override, or omit it entirely.
        let hex: String? = rawString(params, "hex").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized: String? = (hex?.isEmpty == false) ? hex : nil
        guard let ok = context?.controlSetWorkspaceGroupColor(
            routing: routingSelectors(params), groupID: gid, hex: normalized
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString), "custom_color": orNull(normalized)]))
            : .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
    }

    /// `workspace.group.set_icon` — set or clear a group's custom icon.
    func workspaceGroupSetIcon(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let symbol: String? = rawString(params, "symbol").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized: String? = (symbol?.isEmpty == false) ? symbol : nil
        guard let result = context?.controlSetWorkspaceGroupIcon(
            routing: routingSelectors(params), groupID: gid, symbol: normalized
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return result.found
            ? .ok(.object(["group_id": .string(gid.uuidString), "icon_symbol": orNull(result.storedSymbol)]))
            : .err(code: "not_found", message: "Group not found", data: .object(["group_id": .string(gid.uuidString)]))
    }

    // MARK: - Move

    /// `workspace.group.move` — move a group to an absolute or relative position.
    func workspaceGroupMove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let ok = context?.controlMoveWorkspaceGroup(
            routing: routingSelectors(params),
            groupID: gid,
            toIndex: int(params, "to_index"),
            beforeGroupID: uuid(params, "before_group_id"),
            afterGroupID: uuid(params, "after_group_id")
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["group_id": .string(gid.uuidString)]))
            : .err(
                code: "invalid_params",
                message: "Missing or unresolvable target position",
                data: .object(["group_id": .string(gid.uuidString)])
            )
    }

    // MARK: - Focus

    /// `workspace.group.focus` — focus a group's window and select its anchor.
    func workspaceGroupFocus(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let gid = uuid(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let resolution = context?.controlFocusWorkspaceGroup(routing: routingSelectors(params), groupID: gid)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Group or anchor not found", data: .object(["group_id": .string(gid.uuidString)]))
        case .focused(let anchorID):
            return .ok(.object([
                "group_id": .string(gid.uuidString),
                "anchor_workspace_id": .string(anchorID.uuidString),
                "anchor_workspace_ref": ref(.workspace, anchorID),
            ]))
        }
    }

    // MARK: - Local helpers


    /// The localized workspace-group error strings, resolved by the app
    /// conformance against the app bundle.
    private func workspaceGroupStrings() -> ControlWorkspaceGroupStrings {
        context?.controlWorkspaceGroupStrings() ?? ControlWorkspaceGroupStrings(
            allChildrenAreAnchors: "",
            workspaceIsOtherGroupAnchor: ""
        )
    }

    /// A JSON array whose every element is a string, mapped to `[String]`
    /// (mirrors the legacy `params["child_workspace_ids"] as? [String]` cast:
    /// a single string or a mixed array fails and falls to the malformed-shape
    /// branch).
    private func stringArrayExact(_ value: JSONValue?) -> [String]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [String] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard case .string(let string) = element else { return nil }
            out.append(string)
        }
        return out
    }

    /// Whether a JSON value is `null`.
    private func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}
