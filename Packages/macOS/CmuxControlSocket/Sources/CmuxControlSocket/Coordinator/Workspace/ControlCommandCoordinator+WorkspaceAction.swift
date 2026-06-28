internal import Foundation

/// `workspace.action` — the workspace pin/rename/describe/reorder/close/
/// mark/color mutation dispatcher, lifted byte-faithfully from the former
/// `TerminalController.v2WorkspaceAction`.
///
/// The coordinator owns the orchestration: the TabManager-availability and
/// action-key gates, the target resolution, the pure
/// ``ControlWorkspaceActionResolution`` validation (supported-action canon,
/// title/description trimming, named-color→hex), the failure encoding, and the
/// payload assembly (minting `workspace_ref` / `window_ref` through the shared
/// handle registry). Every live `TabManager` / `notificationStore` mutation
/// stays app-side behind a granular ``ControlWorkspaceContext`` witness that
/// returns only the Sendable post-mutation snapshot the payload needs
/// (resulting index, post-clear title, post-set description, closed count).
///
/// Dispatched by `handleSystem` (the legacy switch grouped `workspace.action`
/// with the system/action methods); the mobile data plane reaches the same
/// path through its gated `v2MobileWorkspaceAction` wrapper.
extension ControlCommandCoordinator {
    /// Runs one `workspace.action` request end to end.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully shaped call result.
    func workspaceAction(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let routing = routingSelectors(params)
        guard context.controlWorkspaceRoutingResolvesTabManager(routing: routing) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = actionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        guard let target = context.controlWorkspaceActionResolveTarget(
            routing: routing,
            requestedWorkspaceID: uuid(params, "workspace_id")
        ) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        // The pure resolution owns the supported-action canon, the
        // title/description trimming rules, and the named-color→hex resolution.
        // The palette snapshot is read app-side only for the non-blank
        // `set_color` path (matching the legacy body, which read it after the
        // non-blank color check).
        let colorRaw = string(params, "color")
        let palette: [ControlWorkspaceColorPaletteEntry]
        if action == "set_color", colorRaw != nil {
            palette = context.controlWorkspaceColorPalette()
        } else {
            palette = []
        }

        let plan: ControlWorkspaceActionPlan
        switch ControlWorkspaceActionResolution.resolve(
            action: action,
            title: string(params, "title"),
            description: string(params, "description"),
            color: colorRaw,
            palette: palette
        ) {
        case .unknownAction:
            return .err(code: "invalid_params", message: "Unknown workspace action", data: .object([
                "action": .string(action),
                "supported_actions": .array(ControlWorkspaceActionResolution.supportedActions.map { .string($0) }),
            ]))
        case .missingTitle:
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        case .missingDescription:
            return .err(code: "invalid_params", message: "Missing or invalid description", data: nil)
        case .missingColor:
            return .err(code: "invalid_params", message: "Missing or invalid color", data: nil)
        case .invalidColor(let namedColors):
            return .err(
                code: "invalid_params",
                message: "Invalid color. Use a hex value (#RRGGBB) or a named color.",
                data: .object(["named_colors": .array(namedColors.map { .string($0) })])
            )
        case .planned(let resolvedPlan):
            plan = resolvedPlan
        }

        switch plan {
        case .pin:
            context.controlWorkspaceActionSetPinned(workspaceID: target.workspaceID, pinned: true)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["pinned": .bool(true)]))

        case .unpin:
            context.controlWorkspaceActionSetPinned(workspaceID: target.workspaceID, pinned: false)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["pinned": .bool(false)]))

        case .rename(let title):
            context.controlWorkspaceActionSetCustomTitle(workspaceID: target.workspaceID, title: title)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["title": .string(title)]))

        case .clearName:
            let resultingTitle = context.controlWorkspaceActionClearCustomTitle(workspaceID: target.workspaceID)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["title": .string(resultingTitle)]))

        case .setDescription(let description):
            let resulting = context.controlWorkspaceActionSetCustomDescription(
                workspaceID: target.workspaceID,
                description: description
            )
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["description": orNull(resulting)]))

        case .clearDescription:
            context.controlWorkspaceActionClearCustomDescription(workspaceID: target.workspaceID)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["description": .null]))

        case .moveUp:
            return workspaceActionReorderResult(action: action, target: target, direction: .up, context: context)

        case .moveDown:
            return workspaceActionReorderResult(action: action, target: target, direction: .down, context: context)

        case .moveTop:
            let index = context.controlWorkspaceActionMoveTop(workspaceID: target.workspaceID)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["index": workspaceActionIndexValue(index)]))

        case .closeOthers:
            return workspaceActionCloseResult(action: action, target: target, scope: .others, context: context)

        case .closeAbove:
            return workspaceActionCloseResult(action: action, target: target, scope: .above, context: context)

        case .closeBelow:
            return workspaceActionCloseResult(action: action, target: target, scope: .below, context: context)

        case .markRead:
            context.controlWorkspaceActionMarkRead(workspaceID: target.workspaceID)
            return .ok(workspaceActionPayload(action: action, target: target, extras: [:]))

        case .markUnread:
            context.controlWorkspaceActionMarkUnread(workspaceID: target.workspaceID)
            return .ok(workspaceActionPayload(action: action, target: target, extras: [:]))

        case .setColor(let hex):
            context.controlWorkspaceActionSetTabColor(workspaceID: target.workspaceID, hex: hex)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["color": .string(hex)]))

        case .clearColor:
            context.controlWorkspaceActionSetTabColor(workspaceID: target.workspaceID, hex: nil)
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["color": .null]))
        }
    }

    // MARK: - Plan helpers

    /// Drives the reorder witness and encodes its outcome (the legacy `move_up`
    /// / `move_down` `not_found` guard plus the `index` payload).
    private func workspaceActionReorderResult(
        action: String,
        target: ControlWorkspaceActionTarget,
        direction: ControlWorkspaceActionReorderDirection,
        context: any ControlCommandContext
    ) -> ControlCallResult {
        switch context.controlWorkspaceActionReorder(workspaceID: target.workspaceID, direction: direction) {
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .reordered(let index):
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["index": workspaceActionIndexValue(index)]))
        }
    }

    /// Drives the close witness and encodes its outcome (the legacy
    /// `close_above` / `close_below` `not_found` guard plus the `closed`
    /// payload).
    private func workspaceActionCloseResult(
        action: String,
        target: ControlWorkspaceActionTarget,
        scope: ControlWorkspaceActionCloseScope,
        context: any ControlCommandContext
    ) -> ControlCallResult {
        switch context.controlWorkspaceActionClose(workspaceID: target.workspaceID, scope: scope) {
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .closed(let count):
            return .ok(workspaceActionPayload(action: action, target: target, extras: ["closed": .int(Int64(count))]))
        }
    }

    // MARK: - Payload

    /// Builds the `workspace.action` reply payload: the action-invariant base
    /// (`action`, `workspace_id`, `workspace_ref`, `window_id`, `window_ref`)
    /// merged with the per-action extras, matching the legacy `finish(_:)`.
    private func workspaceActionPayload(
        action: String,
        target: ControlWorkspaceActionTarget,
        extras: [String: JSONValue]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(action),
            "workspace_id": .string(target.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, target.workspaceID),
            "window_id": orNull(target.windowID?.uuidString),
            "window_ref": ref(.window, target.windowID),
        ]
        for (key, value) in extras {
            object[key] = value
        }
        return .object(object)
    }

    /// The legacy `v2OrNull(tabs.firstIndex(...))`: the index as a JSON int, or
    /// JSON `null` when absent.
    private func workspaceActionIndexValue(_ index: Int?) -> JSONValue {
        guard let index else { return .null }
        return .int(Int64(index))
    }
}
