internal import Foundation

/// The workspace domain (the non-group `workspace.*` methods), lifted
/// byte-faithfully from the former `TerminalController.v2Workspace*` bodies.
/// Each payload is built directly as a ``JSONValue`` (the typed twin of the
/// legacy `[String: Any]` dictionaries); the resulting Foundation object is
/// identical, so the encoded wire bytes match.
///
/// The `workspace.group.*` methods live in `+WorkspaceGroup.swift`;
/// `workspace.action` / `extension.sidebar.snapshot` and the worker-lane
/// `workspace.remote.pty_*` (sessions/close/detach/bridge/resize) methods stay
/// on the app-side dispatcher.
extension ControlCommandCoordinator {
    /// Dispatches the non-group workspace methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not an owned workspace method.
    func handleWorkspace(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.list":
            return workspaceList(request.params)
        case "workspace.create":
            return workspaceCreate(request.params)
        case "workspace.select":
            return workspaceSelect(request.params)
        case "workspace.current":
            return workspaceCurrent(request.params)
        case "workspace.close":
            return workspaceClose(request.params)
        case "workspace.move_to_window":
            return workspaceMoveToWindow(request.params)
        case "workspace.reorder":
            return workspaceReorder(request.params)
        case "workspace.reorder_many":
            return workspaceReorderMany(request.params)
        case "workspace.prompt_submit":
            return workspacePromptSubmit(request.params)
        case "workspace.rename":
            return workspaceRename(request.params)
        case "workspace.next":
            return workspaceNext(request.params)
        case "workspace.previous":
            return workspacePrevious(request.params)
        case "workspace.last":
            return workspaceLast(request.params)
        case "workspace.equalize_splits":
            return workspaceEqualizeSplits(request.params)
        case "workspace.remote.configure":
            return workspaceRemoteConfigure(request.params)
        case "workspace.remote.foreground_auth_ready":
            return workspaceRemoteForegroundAuthReady(request.params)
        case "workspace.remote.reconnect":
            return workspaceRemoteReconnect(request.params)
        case "workspace.remote.disconnect":
            return workspaceRemoteDisconnect(request.params)
        case "workspace.remote.status":
            return workspaceRemoteStatus(request.params)
        case "workspace.remote.pty_attach_end":
            return workspaceRemotePTYAttachEnd(request.params)
        case "workspace.remote.terminal_session_end":
            return workspaceRemoteTerminalSessionEnd(request.params)
        default:
            return nil
        }
    }

    // MARK: - Summary payload

    /// Builds one workspace summary payload, minting the workspace ref and caller-owned selection keys.
    private func workspaceSummaryPayload(
        _ summary: ControlWorkspaceSummary,
        index: Int?,
        selected: Bool
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(summary.id.uuidString),
            "ref": ref(.workspace, summary.id),
            "title": .string(summary.title),
            "custom_title": orNull(summary.customTitle),
            "has_custom_title": .bool(!(summary.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
            "description": orNull(summary.customDescription),
            "selected": .bool(selected),
            "pinned": .bool(summary.isPinned),
            "listening_ports": .array(summary.listeningPorts.map { .int(Int64($0)) }),
            "remote": summary.remoteStatus,
            "current_directory": orNull(summary.currentDirectory),
            "custom_color": orNull(summary.customColor),
            "latest_conversation_message": orNull(summary.latestConversationMessage),
            "latest_submitted_message": orNull(summary.latestSubmittedMessage),
            "latest_submitted_at": orNull(summary.latestSubmittedAt),
        ]
        if let index {
            object["index"] = .int(Int64(index))
        }
        return .object(object)
    }

    // MARK: - List / current

    /// `workspace.list` — every workspace in the resolved window.
    func workspaceList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceList(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .resolved(let windowID, let workspaces, let selectedIndex):
            let rows: [JSONValue] = workspaces.enumerated().map { index, summary in
                workspaceSummaryPayload(summary, index: index, selected: index == selectedIndex)
            }
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspaces": .array(rows),
            ]))
        }
    }

    /// `workspace.current` — the selected workspace in the resolved window.
    func workspaceCurrent(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceCurrent(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .noWorkspaceSelected:
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        case .resolved(let windowID, let workspaceID, let index, let summary):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "workspace": summary.map { workspaceSummaryPayload($0, index: index, selected: true) } ?? .null,
            ]))
        }
    }

    // MARK: - Create

    /// `workspace.create` — create a workspace.
    ///
    /// A passthrough to the still-shared `v2WorkspaceCreate(params:tabManager:)`
    /// (which the mobile data-plane `v2MobileWorkspaceCreate` also drives), rather
    /// than a typed lift: the create body parses all ~10 params and mints refs
    /// itself, so a single source of truth is both deduplicated and exactly
    /// faithful. The conformance bridges the body's Foundation payload to a
    /// `ControlCallResult`, like `surface.move` / `debug.terminals`.
    func workspaceCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        context?.controlWorkspaceCreate(params: params)
            ?? .err(code: "unavailable", message: "TabManager not available", data: nil)
    }

    // MARK: - Select / close / move

    /// `workspace.select` — select a workspace by id.
    func workspaceSelect(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let resolution = context?.controlSelectWorkspace(
            routing: routing,
            workspaceID: workspaceID
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        }
    }

    /// `workspace.close` — close a workspace by id.
    func workspaceClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let resolution = context?.controlCloseWorkspace(
            routing: routing,
            workspaceID: workspaceID
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .protected(let windowID):
            let message = context?.controlWorkspaceStrings().closeProtected ?? ""
            return .err(code: "protected", message: message, data: .object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pinned": .bool(true),
            ]))
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        }
    }

    /// `workspace.move_to_window` — move a workspace to another window.
    func workspaceMoveToWindow(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let focusRequested = bool(params, "focus") ?? false
        guard let resolution = context?.controlMoveWorkspaceToWindow(
            workspaceID: workspaceID,
            windowID: windowID,
            focusRequested: focusRequested
        ) else {
            return .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        }
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
            ]))
        case .windowNotFound:
            return .err(code: "not_found", message: "Window not found", data: .object([
                "window_id": .string(windowID.uuidString),
            ]))
        case .resolved:
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - Reorder

    /// Builds one reorder plan item's payload (the legacy
    /// `v2WorkspaceReorderPlanPayload`).
    private func workspaceReorderPlanPayload(
        _ plan: ControlWorkspaceReorderPlanItem,
        windowID: UUID?
    ) -> JSONValue {
        .object([
            "workspace_id": .string(plan.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, plan.workspaceID),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "from_index": .int(Int64(plan.fromIndex)),
            "to_index": .int(Int64(plan.toIndex)),
        ])
    }

    /// `workspace.reorder` — move one workspace to an index/relative target.
    func workspaceReorder(_ params: [String: JSONValue]) -> ControlCallResult {
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routingSelectors(params)) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let index = int(params, "index")
        let beforeID = uuid(params, "before_workspace_id")
        let afterID = uuid(params, "after_workspace_id")
        let dryRun = bool(params, "dry_run") ?? false

        let targetCount = (index != nil ? 1 : 0) + (beforeID != nil ? 1 : 0) + (afterID != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one target: index, before_workspace_id, or after_workspace_id",
                data: nil
            )
        }

        let resolution = context?.controlReorderWorkspace(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            toIndex: index,
            beforeWorkspaceID: beforeID,
            afterWorkspaceID: afterID,
            dryRun: dryRun
        ) ?? .notFound
        switch resolution {
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
            ]))
        case .resolved(let windowID, let plan):
            var object: [String: JSONValue] = [
                "workspace_id": .string(plan.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, plan.workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "from_index": .int(Int64(plan.fromIndex)),
                "to_index": .int(Int64(plan.toIndex)),
            ]
            object["dry_run"] = .bool(dryRun)
            object["index"] = .int(Int64(plan.toIndex))
            object["plan"] = .array([workspaceReorderPlanPayload(plan, windowID: windowID)])
            object["events"] = (!dryRun && plan.fromIndex != plan.toIndex)
                ? .array([workspaceReorderPlanPayload(plan, windowID: windowID)])
                : .array([])
            return .ok(.object(object))
        }
    }

    /// `workspace.reorder_many` — apply a desired workspace order.
    func workspaceReorderMany(_ params: [String: JSONValue]) -> ControlCallResult {
        let strings = context?.controlWorkspaceStrings()

        let rawOrder = workspaceReorderManyOrder(params)
        if let invalid = rawOrder.invalidValue {
            return .err(
                code: "invalid_params",
                message: strings?.reorderManyInvalidWorkspace ?? "",
                data: .object(["workspace": .string(invalid)])
            )
        }
        let order = rawOrder.order
        guard !order.isEmpty else {
            return .err(
                code: "invalid_params",
                message: strings?.reorderManyMissingOrder ?? "",
                data: nil
            )
        }

        var workspaceIDs: [UUID] = []
        workspaceIDs.reserveCapacity(order.count)
        for raw in order {
            guard let workspaceID = uuidAny(.string(raw)) else {
                return .err(
                    code: "invalid_params",
                    message: strings?.reorderManyInvalidWorkspace ?? "",
                    data: .object(["workspace": .string(raw)])
                )
            }
            workspaceIDs.append(workspaceID)
        }

        let dryRun = bool(params, "dry_run") ?? false
        let resolution = context?.controlReorderWorkspacesMany(
            routing: routingSelectors(params),
            workspaceIDs: workspaceIDs,
            dryRun: dryRun
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(
                code: "unavailable",
                message: strings?.reorderManyTabManagerUnavailable ?? "",
                data: nil
            )
        case .duplicateWorkspace(let workspaceID):
            return .err(
                code: "invalid_params",
                message: strings?.reorderManyDuplicateWorkspace ?? "",
                data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "workspace_ref": ref(.workspace, workspaceID),
                ])
            )
        case .workspaceNotFound(let workspaceID):
            return .err(
                code: "not_found",
                message: strings?.reorderManyWorkspaceNotFound ?? "",
                data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "workspace_ref": ref(.workspace, workspaceID),
                ])
            )
        case .resolved(let windowID, let plans):
            let planPayloads = plans.map { workspaceReorderPlanPayload($0, windowID: windowID) }
            let events: [JSONValue] = dryRun
                ? []
                : zip(plans, planPayloads).compactMap { plan, payload in
                    plan.fromIndex != plan.toIndex ? payload : nil
                }
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "dry_run": .bool(dryRun),
                "plan": .array(planPayloads),
                "events": .array(events),
            ]))
        }
    }

    /// Parses the `workspace_ids` / `order` params for `workspace.reorder_many`
    /// (the legacy `v2WorkspaceReorderManyOrder`), returning the trimmed order
    /// or the JSON-encoded invalid value description.
    private func workspaceReorderManyOrder(
        _ params: [String: JSONValue]
    ) -> (order: [String], invalidValue: String?) {
        if let raw = params["workspace_ids"], !isNull(raw) {
            switch raw {
            case .array(let values):
                var strings: [String] = []
                strings.reserveCapacity(values.count)
                for item in values {
                    guard case .string(let value) = item else {
                        return ([], invalidValueDescription(
                            item,
                            fallback: "<invalid_workspace_id>"
                        ))
                    }
                    strings.append(value)
                }
                return normalizeReorderManyOrder(strings)
            case .string(let value):
                return normalizeReorderManyOrder([value])
            default:
                return ([], invalidValueDescription(
                    raw,
                    fallback: "<invalid_workspace_ids>"
                ))
            }
        }

        guard let order = params["order"], !isNull(order) else { return ([], nil) }
        guard case .string(let orderString) = order else {
            return ([], invalidValueDescription(
                order,
                fallback: "<invalid_order_value>"
            ))
        }
        let refs = orderString
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return normalizeReorderManyOrder(refs)
    }

    /// The legacy `v2NormalizeWorkspaceReorderManyOrder`: trimmed entries, with
    /// the first empty entry reported as the invalid value (its raw form).
    private func normalizeReorderManyOrder(
        _ rawItems: [String]
    ) -> (order: [String], invalidValue: String?) {
        var order: [String] = []
        order.reserveCapacity(rawItems.count)
        for raw in rawItems {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ([], raw)
            }
            order.append(trimmed)
        }
        return (order, nil)
    }

    /// The legacy `v2WorkspaceReorderManyInvalidValueDescription`: the JSON
    /// encoding of `{"value": <raw>}`, or the fallback when it can't encode.
    private func invalidValueDescription(_ value: JSONValue, fallback: String) -> String {
        let wrapped: [String: Any] = ["value": value.foundationObject]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: []),
              let encoded = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return encoded
    }

    // MARK: - Prompt submit / rename

    /// `workspace.prompt_submit` — submit a prompt into a workspace.
    func workspacePromptSubmit(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let messageKeys = ["message", "prompt", "text", "body"]
        for key in messageKeys {
            guard let raw = params[key], !isNull(raw) else { continue }
            guard case .string = raw else {
                return .err(code: "invalid_params", message: "\(key) must be a string", data: nil)
            }
        }
        let message = messageKeys.lazy.compactMap { self.rawString(params, $0) }.first

        let resolution = context?.controlSubmitWorkspacePrompt(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            message: message
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
            ]))
        case .resolved(let windowID, let iMessageModeEnabled, let messageRecorded, let reordered, let index, let preview):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "i_message_mode_enabled": .bool(iMessageModeEnabled),
                "message_recorded": .bool(messageRecorded),
                "message_preview": orNull(preview),
                "reordered": .bool(reordered),
                "index": .int(Int64(index)),
            ]))
        }
    }

    /// `workspace.rename` — set a workspace's custom title.
    func workspaceRename(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        // Legacy resolved the TabManager BEFORE param validation, so unresolvable
        // routing wins over a missing/invalid param (`unavailable` first).
        guard context?.controlWorkspaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let title = string(params, "title") else {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }
        let resolution = context?.controlRenameWorkspace(
            routing: routing,
            workspaceID: workspaceID,
            title: title
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "title": .string(title),
            ]))
        }
    }

    // MARK: - Navigation

    /// Shapes the shared navigation result for next/previous/last.
    private func workspaceNavigationResult(
        _ resolution: ControlWorkspaceNavigationResolution?,
        notFoundMessage: String
    ) -> ControlCallResult {
        switch resolution ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: notFoundMessage, data: nil)
        case .resolved(let workspaceID, let windowID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    /// `workspace.next` — select the next workspace.
    func workspaceNext(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectNextWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No workspace selected"
        )
    }

    /// `workspace.previous` — select the previous workspace.
    func workspacePrevious(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectPreviousWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No workspace selected"
        )
    }

    /// `workspace.last` — navigate to the previously-selected workspace.
    func workspaceLast(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceNavigationResult(
            context?.controlSelectLastWorkspace(routing: routingSelectors(params)),
            notFoundMessage: "No previous workspace in history"
        )
    }

    // MARK: - Equalize

    /// `workspace.equalize_splits` — equalize the resolved workspace's splits.
    func workspaceEqualizeSplits(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlEqualizeWorkspaceSplits(
            routing: routingSelectors(params),
            orientationFilter: string(params, "orientation")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .resolved(let workspaceID, let equalized):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "equalized": .bool(equalized),
            ]))
        }
    }

    // MARK: - Remote

    /// Shapes the shared remote-mutation result for disconnect / reconnect /
    /// foreground_auth_ready / status.
    private func workspaceRemoteResult(_ resolution: ControlWorkspaceRemoteResolution?) -> ControlCallResult {
        switch resolution ?? .missingWorkspaceID {
        case .missingWorkspaceID:
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        case .notFound(let workspaceID):
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .notConfigured(let workspaceID):
            return .err(code: "invalid_state", message: "Remote workspace is not configured", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .resolved(let windowID, let workspaceID, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "remote": remoteStatus,
            ]))
        }
    }

    /// Resolves the explicit-or-fallback workspace id for the remote methods,
    /// reproducing the legacy `requestedWorkspaceId ?? selectedTabId` rule and
    /// its two `invalid_params` failures.
    private func remoteWorkspaceID(
        _ params: [String: JSONValue]
    ) -> (workspaceID: UUID?, error: ControlCallResult?) {
        let requested = uuid(params, "workspace_id")
        if hasNonNull(params, "workspace_id"), requested == nil {
            return (nil, .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        let resolved = context?.controlResolveRemoteWorkspaceID(
            routing: routingSelectors(params),
            requestedWorkspaceID: requested
        )
        guard let resolved else {
            return (nil, .err(code: "invalid_params", message: "Missing workspace_id", data: nil))
        }
        return (resolved, nil)
    }

    /// `workspace.remote.configure` — configure a workspace's remote connection.
    func workspaceRemoteConfigure(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        return context?.controlConfigureWorkspaceRemote(params: params, workspaceID: workspaceID)
            ?? .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
    }

    /// `workspace.remote.disconnect` — disconnect a workspace's remote.
    func workspaceRemoteDisconnect(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let clearConfiguration = bool(params, "clear") ?? false
        return workspaceRemoteResult(context?.controlDisconnectWorkspaceRemote(
            workspaceID: workspaceID,
            clearConfiguration: clearConfiguration
        ))
    }

    /// `workspace.remote.reconnect` — reconnect a workspace's remote.
    func workspaceRemoteReconnect(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), surfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        return workspaceRemoteResult(context?.controlReconnectWorkspaceRemote(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ))
    }

    /// `workspace.remote.foreground_auth_ready` — arm/continue a pending connect.
    func workspaceRemoteForegroundAuthReady(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        // Legacy `v2RawString(...)?.trimmingCharacters(...)`: trimmed, but an
        // empty string stays "" (NOT nil), so use the raw-trim, not the
        // empty-to-nil variant.
        let token = rawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaceRemoteResult(context?.controlWorkspaceRemoteForegroundAuthReady(
            workspaceID: workspaceID,
            foregroundAuthToken: token
        ))
    }

    /// `workspace.remote.status` — read a workspace's remote status.
    func workspaceRemoteStatus(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = remoteWorkspaceID(params)
        if let error = resolution.error { return error }
        guard let workspaceID = resolution.workspaceID else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        return workspaceRemoteResult(context?.controlWorkspaceRemoteStatus(workspaceID: workspaceID))
    }

    /// `workspace.remote.pty_attach_end` — record a remote PTY attach end.
    func workspaceRemotePTYAttachEnd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let sessionID = optionalTrimmedRawString(params, "session_id") else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }

        let resolution = context?.controlWorkspaceRemotePTYAttachEnd(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID
        ) ?? .notFound
        switch resolution {
        case .notFound:
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "session_id": .string(sessionID),
                "workspace_found": .bool(false),
                "cleared_remote_pty_session": .bool(false),
                "untracked_remote_terminal": .bool(false),
            ]))
        case .resolved(let windowID, let resolvedWorkspaceID, let cleared, let untracked, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(resolvedWorkspaceID.uuidString),
                "workspace_ref": ref(.workspace, resolvedWorkspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "session_id": .string(sessionID),
                "workspace_found": .bool(true),
                "cleared_remote_pty_session": .bool(cleared),
                "untracked_remote_terminal": .bool(untracked),
                "remote": remoteStatus,
            ]))
        }
    }

    /// `workspace.remote.terminal_session_end` — record a remote terminal
    /// session end.
    func workspaceRemoteTerminalSessionEnd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let relayPort = strictInt(params, "relay_port"), relayPort > 0, relayPort <= 65535 else {
            return .err(code: "invalid_params", message: "Missing or invalid relay_port", data: nil)
        }

        let resolution = context?.controlWorkspaceRemoteTerminalSessionEnd(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            relayPort: relayPort
        ) ?? .notFound
        switch resolution {
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "relay_port": .int(Int64(relayPort)),
            ]))
        case .resolved(let windowID, let resolvedWorkspaceID, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(resolvedWorkspaceID.uuidString),
                "workspace_ref": ref(.workspace, resolvedWorkspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "relay_port": .int(Int64(relayPort)),
                "remote": remoteStatus,
            ]))
        }
    }

    /// `v2HasNonNullParam`-style null test on a typed value.
    private func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}
