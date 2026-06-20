internal import Foundation

/// Agent-facing helper setup commands. These intentionally compose existing
/// pane/surface mutation paths so helper automation gets one hard-to-misuse
/// entrypoint without forking split creation or focus policy.
extension ControlCommandCoordinator {
    func handleHelper(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "helper.visible":
            return .err(
                code: "invalid_dispatch",
                message: "helper.visible must run on the socket worker",
                data: nil
            )
        default:
            return nil
        }
    }

    func handleHelperAsync(_ request: ControlRequest) async -> ControlCallResult? {
        switch request.method {
        case "helper.visible":
            return await helperVisible(request.params)
        default:
            return nil
        }
    }

    /// `helper.visible` creates or reuses a right-side helper pane in the
    /// visually focused workspace. The response carries caller and focused
    /// identity so caller-vs-focused divergence stays explicit to automation.
    func helperVisible(_ params: [String: JSONValue]) async -> ControlCallResult {
        let targetRaw = string(params, "target") ?? "focused"
        guard normalizedToken(targetRaw) == "focused" else {
            return .err(
                code: "invalid_params",
                message: "helper.visible only supports target=focused",
                data: .object(["target": .string(targetRaw)])
            )
        }

        let typeRaw = string(params, "type")
        switch normalizedToken(typeRaw ?? "terminal") {
        case "terminal", "browser":
            break
        default:
            return .err(
                code: "invalid_params",
                message: "helper.visible supports type=terminal or type=browser",
                data: typeRaw.map { .object(["type": .string($0)]) }
            )
        }

        var identifyParams: [String: JSONValue] = [:]
        if case .object(let callerObject)? = params["caller"], !callerObject.isEmpty {
            identifyParams["caller"] = .object(callerObject)
        }
        if let windowID = uuid(params, "window_id") {
            identifyParams["window_id"] = .string(windowID.uuidString)
        } else if params["window_id"] != nil {
            return .err(code: "invalid_params", message: "Invalid window_id", data: params["window_id"])
        }

        let identify = helperVisibleIdentifyPayload(params: identifyParams)
        guard let focusedWorkspaceID = uuidAny(identify.focused["workspace_id"]) else {
            return .err(code: "not_found", message: "Focused workspace not found", data: nil)
        }

        var routingParams: [String: JSONValue] = [
            "workspace_id": .string(focusedWorkspaceID.uuidString),
        ]
        let focusedWindowID = uuidAny(identify.focused["window_id"])
        if let focusedWindowID {
            routingParams["window_id"] = .string(focusedWindowID.uuidString)
        }
        let routing = routingSelectors(routingParams)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let snapshot = context?.controlPaneList(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let initialHealth = context?.controlSurfaceHealth(routing: routing) else {
            return helperVisibleVisibilityError(
                message: "helper.visible cannot verify target workspace surface visibility",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: ["visibility_source": .string("surface.health")]
            )
        }

        let requestedType = normalizedToken(typeRaw ?? "terminal")
        switch helperVisiblePlacement(
            in: snapshot,
            focused: identify.focused,
            health: initialHealth,
            requestedType: requestedType
        ) {
        case .reuse(let helperPane, let helperSurface):
            let result = helperVisibleReuseResult(
                helperPane: helperPane,
                helperSurface: helperSurface,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID
            )
            return await helperVisibleAnnotateAndVerify(
                result,
                params: params,
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                routing: routing,
                placementStrategy: "reused_right_pane",
                reusedPane: true,
                createdPane: false,
                createdSurface: false,
                paneID: helperPane.paneID
            )
        case .blockedInvisible(let helperPane):
            return helperVisibleVisibilityError(
                message: "helper.visible found a structural helper pane, but none of its surfaces are visible in the target window",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: [
                    "pane_id": .string(helperPane.paneID.uuidString),
                    "pane_ref": ref(.pane, helperPane.paneID),
                    "surface_ids": .array(helperPane.surfaceIDs.map { .string($0.uuidString) }),
                    "surface_refs": .array(helperPane.surfaceIDs.map { ref(.surface, $0) }),
                    "surface_health": helperVisibleHealthPayload(initialHealth),
                ]
            )
        case .create:
            break
        }

        var createParams = helperVisibleBaseCreateParams(
            from: params,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedWindowID: focusedWindowID
        )
        createParams["direction"] = .string("right")
        let result = paneCreate(createParams)
        return await helperVisibleAnnotateAndVerify(
            result,
            params: params,
            identify: identify,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedWindowID: focusedWindowID,
            routing: routing,
            placementStrategy: "created_right_pane",
            reusedPane: false,
            createdPane: true,
            createdSurface: true,
            paneID: nil
        )
    }
}
