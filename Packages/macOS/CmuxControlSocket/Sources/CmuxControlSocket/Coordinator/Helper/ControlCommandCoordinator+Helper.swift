internal import Dispatch
internal import Foundation

private let helperVisibleMutationStartDeadlineParam =
    "_cmux_helper_visible_latest_mutation_start_uptime_ns"

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
        guard helperVisibleTargetSurfaceIsVisible(
            in: snapshot,
            focused: identify.focused,
            health: initialHealth
        ) else {
            return helperVisibleVisibilityError(
                message: "helper.visible cannot verify that the target workspace is visible in the target window",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: [
                    "visibility_source": .string("surface.health"),
                    "target_surface_visible": .bool(false),
                    "surface_health": helperVisibleHealthPayload(initialHealth),
                ]
            )
        }

        let requestedType = normalizedToken(typeRaw ?? "terminal")
        if requestedType != "terminal",
           (string(params, "command") != nil || string(params, "initial_command") != nil) {
            return helperVisibleUnsupportedError(
                code: "invalid_params",
                message: "helper.visible command delivery is only supported for terminal helpers",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: [
                    "type": .string(requestedType),
                    "mutation_started": .bool(false),
                    "placement_strategy": .string("non_terminal_command_rejected_before_mutation"),
                ]
            )
        }
        switch helperVisiblePlacement(
            in: snapshot,
            focused: identify.focused,
            health: initialHealth,
            requestedType: requestedType
        ) {
        case .reuse(let helperPane, let helperSurface):
            if requestedType == "browser", string(params, "url") != nil {
                return helperVisibleUnsupportedError(
                    code: "unsupported",
                    message: "helper.visible cannot reuse an existing browser helper for a requested URL",
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    extra: [
                        "pane_id": .string(helperPane.paneID.uuidString),
                        "pane_ref": ref(.pane, helperPane.paneID),
                        "surface_id": .string(helperSurface.surfaceID.uuidString),
                        "surface_ref": ref(.surface, helperSurface.surfaceID),
                        "type": .string(helperSurface.typeRawValue),
                        "mutation_started": .bool(false),
                        "placement_strategy": .string("browser_url_reuse_rejected_before_mutation"),
                    ]
                )
            }
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
            if Task.isCancelled {
                return helperVisibleUnsupportedError(
                    code: "cancelled",
                    message: "helper.visible was cancelled before creating a helper pane",
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    extra: [
                        "mutation_started": .bool(false),
                        "placement_strategy": .string("cancelled_before_create"),
                    ]
                )
            }
            if helperVisibleMutationDeadlineExpired(params) {
                return helperVisibleUnsupportedError(
                    code: "timeout",
                    message: "helper.visible timed out before creating a helper pane",
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    extra: [
                        "mutation_started": .bool(false),
                        "placement_strategy": .string("deadline_expired_before_create"),
                    ]
                )
            }
            if snapshot.isRemoteTmuxMirror, requestedType == "terminal" {
                return helperVisibleUnsupportedError(
                    code: "unsupported",
                    message: "helper.visible cannot create a visible terminal helper in a remote tmux mirror workspace",
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    extra: [
                        "routed_target": .string("remote-tmux"),
                        "placement_strategy": .string("remote_tmux_rejected_before_mutation"),
                    ]
                )
            }
            if requestedType == "browser", context?.controlPaneBrowserCreationDisabled() == true {
                return helperVisibleUnsupportedError(
                    code: "browser_disabled",
                    message: "helper.visible cannot create a visible browser helper while the cmux browser is disabled",
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    extra: [
                        "mutation_started": .bool(false),
                        "placement_strategy": .string("browser_disabled_rejected_before_mutation"),
                    ]
                )
            }
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

    private func helperVisibleMutationDeadlineExpired(_ params: [String: JSONValue]) -> Bool {
        guard let latestMutationStart = int(params, helperVisibleMutationStartDeadlineParam),
              latestMutationStart > 0 else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds > UInt64(latestMutationStart)
    }
}
