internal import Foundation

/// The session-priority domain (`session_priority.get/set/status`): the
/// per-workspace difficulty and manual flag behind effort distribution, and
/// the ranked list of a window's Claude workspaces. Relay-denied.
extension ControlCommandCoordinator {
    /// Dispatches the session-priority methods; `nil` for anything else.
    func handleSessionPriority(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "session_priority.get":
            return sessionPriorityGet(request.params)
        case "session_priority.set":
            return sessionPrioritySet(request.params)
        case "session_priority.status":
            return sessionPriorityStatus(request.params)
        default:
            return nil
        }
    }

    // MARK: - Payloads

    private func sessionPriorityPayload(
        windowID: UUID?,
        snapshot: ControlSessionPrioritySnapshot
    ) -> JSONValue {
        let target: JSONValue
        if snapshot.targetEffort != nil || snapshot.targetModel != nil {
            target = .object([
                "effort": orNull(snapshot.targetEffort),
                "model": orNull(snapshot.targetModel),
            ])
        } else {
            target = .null
        }
        return .object([
            "workspace_id": .string(snapshot.workspaceId.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceId),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "enabled": .bool(snapshot.enabled),
            "tier": orNull(snapshot.tier),
            "difficulty": .string(snapshot.difficulty),
            "difficulty_source": .string(snapshot.difficultySource),
            "difficulty_override": orNull(snapshot.difficultyOverride),
            "difficulty_auto": orNull(snapshot.difficultyAuto),
            "manual": .bool(snapshot.manual),
            "manual_signal": orNull(snapshot.manualSignal),
            "target": target,
            "panes": .array(snapshot.panes.map { pane in
                .object([
                    "surface_id": .string(pane.surfaceId.uuidString),
                    "session_id": orNull(pane.sessionId),
                    "current_effort": orNull(pane.currentEffort),
                    "state": .string(pane.state),
                    "detail": orNull(pane.detail),
                ])
            }),
        ])
    }

    private func sessionPriorityResult(_ resolution: ControlSessionPriorityResolution) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .invalidDifficulty(let raw):
            return .err(
                code: "invalid_difficulty",
                message: "difficulty must be one of: easy, normal, hard, auto",
                data: .object(["difficulty": .string(raw)])
            )
        case .resolved(let windowID, let snapshot):
            return .ok(sessionPriorityPayload(windowID: windowID, snapshot: snapshot))
        }
    }

    // MARK: - Methods

    /// `session_priority.get` — one workspace's session priority.
    func sessionPriorityGet(_ params: [String: JSONValue]) -> ControlCallResult {
        sessionPriorityResult(
            context?.controlSessionPriority(
                routing: routingSelectors(params),
                workspaceID: uuid(params, "workspace_id")
            ) ?? .tabManagerUnavailable
        )
    }

    /// `session_priority.set` — set the difficulty override / manual flag,
    /// record the auto difficulty (`source: auto`), or `probe`.
    func sessionPrioritySet(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        let workspaceID = uuid(params, "workspace_id")

        if bool(params, "probe") == true {
            guard let probe = context?.controlProbeSessionPriority(
                routing: routing,
                workspaceID: workspaceID
            ) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            return .ok(.object([
                "enabled": .bool(probe.enabled),
                "workspace_id": .string(probe.workspaceId.uuidString),
                "manual": .bool(probe.manual),
                "override_present": .bool(probe.overridePresent),
            ]))
        }

        let source = string(params, "source")?.lowercased() ?? "user"
        guard source == "user" || source == "auto" else {
            return .err(code: "invalid_params", message: "source must be one of: user, auto", data: nil)
        }
        let difficultyPresent = params["difficulty"] != nil && params["difficulty"] != .null
        let difficulty = string(params, "difficulty")?.lowercased()
        if difficultyPresent, difficulty == nil {
            return .err(code: "invalid_params", message: "Missing or invalid difficulty", data: nil)
        }
        let manualPresent = params["manual"] != nil && params["manual"] != .null
        let manual = manualPresent ? bool(params, "manual") : nil
        if manualPresent, manual == nil {
            return .err(code: "invalid_params", message: "Missing or invalid manual", data: nil)
        }
        guard difficulty != nil || manual != nil else {
            return .err(code: "invalid_params", message: "Provide difficulty and/or manual", data: nil)
        }
        if source == "auto" {
            guard let difficulty, difficulty != "auto" else {
                return .err(
                    code: "invalid_params",
                    message: "source auto requires a difficulty other than auto",
                    data: nil
                )
            }
            guard manual == nil else {
                return .err(code: "invalid_params", message: "source auto does not accept manual", data: nil)
            }
        }
        let clear = difficulty == "auto"
        return sessionPriorityResult(
            context?.controlSetSessionPriority(
                routing: routing,
                workspaceID: workspaceID,
                difficultyRaw: clear ? nil : difficulty,
                clearDifficulty: clear,
                manual: manual,
                source: source
            ) ?? .tabManagerUnavailable
        )
    }

    /// `session_priority.status` — the routed window's ranked Claude workspaces.
    func sessionPriorityStatus(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlSessionPriorityStatus(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .resolved(let windowID, let enabled, let urgentCount, let workspaces):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "enabled": .bool(enabled),
                "urgent_count": .int(Int64(urgentCount)),
                "workspaces": .array(workspaces.map { sessionPriorityPayload(windowID: windowID, snapshot: $0) }),
            ]))
        }
    }
}
