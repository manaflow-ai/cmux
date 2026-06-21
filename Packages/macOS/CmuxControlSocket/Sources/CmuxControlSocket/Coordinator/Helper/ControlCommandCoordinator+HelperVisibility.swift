internal import Foundation

extension ControlCommandCoordinator {
    func helperVisibleAnnotateAndVerify(
        _ result: ControlCallResult,
        params: [String: JSONValue],
        identify: HelperVisibleIdentify,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?,
        routing: ControlRoutingSelectors,
        placementStrategy: String,
        reusedPane: Bool,
        createdPane: Bool,
        createdSurface: Bool,
        paneID: UUID?
    ) async -> ControlCallResult {
        guard case .ok(.object(var payload)) = result else { return result }

        if payload["pane_id"] == nil, let paneID {
            payload["pane_id"] = .string(paneID.uuidString)
            payload["pane_ref"] = ref(.pane, paneID)
        }
        let callerWorkspaceID = uuidAny(identify.caller["workspace_id"])
        let diverged = callerWorkspaceID.map { $0 != focusedWorkspaceID } ?? false
        payload["target_workspace_source"] = .string("focused")
        payload["caller_focused_diverged"] = .bool(diverged)
        payload["placement_strategy"] = .string(placementStrategy)
        payload["reused_pane"] = .bool(reusedPane)
        payload["created_pane"] = .bool(createdPane)
        payload["created_surface"] = .bool(createdSurface)
        payload["sent_command"] = .bool(false)
        payload["focused"] = identify.focused.isEmpty ? .null : .object(identify.focused)
        payload["caller"] = identify.caller.isEmpty ? .null : .object(identify.caller)
        guard let surfaceID = uuidAny(payload["surface_id"]) else {
            payload["surface_visible"] = .bool(false)
            return helperVisibleVisibilityError(
                message: "helper.visible did not create a helper surface in the target window",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: payload
            )
        }

        let visibility = await helperVisibleSurfaceVisibility(
            surfaceID: surfaceID,
            routing: routing,
            waitForWindowEvent: createdSurface
        )
        payload["surface_visible"] = .bool(visibility.isVisible)
        payload["surface_health_found"] = .bool(visibility.entry != nil)
        payload["surface_health_in_window"] = visibility.entry?.inWindow.map { .bool($0) } ?? .null
        payload["surface_health_attempts"] = .int(Int64(visibility.attempts))
        payload["surface_window_event_observed"] = visibility.windowEventObserved.map { .bool($0) } ?? .null
        if let health = visibility.snapshot {
            payload["surface_health"] = helperVisibleHealthPayload(health)
        }
        guard visibility.isVisible else {
            return helperVisibleVisibilityError(
                message: "helper.visible created or reused a helper surface, but surface.health did not report in_window=true",
                identify: identify,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID,
                extra: payload
            )
        }
        if let command = helperVisibleCommandText(params) {
            let sendResult = helperVisibleSendCommand(
                command,
                surfaceID: surfaceID,
                focusedWorkspaceID: focusedWorkspaceID,
                focusedWindowID: focusedWindowID
            )
            guard case .ok(.object(let sendPayload)) = sendResult else {
                payload["sent_command"] = .bool(false)
                payload["command"] = .string(command)
                return helperVisibleCommandError(
                    sendResult,
                    identify: identify,
                    focusedWorkspaceID: focusedWorkspaceID,
                    focusedWindowID: focusedWindowID,
                    payload: payload
                )
            }
            payload["sent_command"] = .bool(true)
            payload["command_queued"] = sendPayload["queued"] ?? .null
        }
        return .ok(.object(payload))
    }

    private func helperVisibleCommandText(_ params: [String: JSONValue]) -> String? {
        string(params, "command") ?? string(params, "initial_command")
    }

    private func helperVisibleSendCommand(
        _ command: String,
        surfaceID: UUID,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?
    ) -> ControlCallResult {
        var text = command
        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        var sendParams: [String: JSONValue] = [
            "workspace_id": .string(focusedWorkspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
            "text": .string(text),
        ]
        if let focusedWindowID {
            sendParams["window_id"] = .string(focusedWindowID.uuidString)
        }
        return surfaceSendText(sendParams)
    }

    private func helperVisibleCommandError(
        _ sendResult: ControlCallResult,
        identify: HelperVisibleIdentify,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?,
        payload: [String: JSONValue]
    ) -> ControlCallResult {
        var extra = payload
        if case .err(let code, let message, let data) = sendResult {
            extra["send_error"] = .object([
                "code": .string(code),
                "message": .string(message),
                "data": data ?? .null,
            ])
        }
        return helperVisibleCommandFailureError(
            message: "helper.visible verified a visible helper surface, but failed to send the requested command",
            identify: identify,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedWindowID: focusedWindowID,
            extra: extra
        )
    }

    private func helperVisibleSurfaceVisibility(
        surfaceID: UUID,
        routing: ControlRoutingSelectors,
        waitForWindowEvent: Bool
    ) async -> (
        isVisible: Bool,
        entry: ControlSurfaceHealthEntry?,
        snapshot: ControlSurfaceHealthSnapshot?,
        attempts: Int,
        windowEventObserved: Bool?
    ) {
        let windowEventObserved: Bool?
        if waitForWindowEvent {
            windowEventObserved = await context?.controlSurfaceWaitForInWindow(
                routing: routing,
                surfaceID: surfaceID
            ) ?? false
        } else {
            windowEventObserved = nil
        }
        guard let snapshot = context?.controlSurfaceHealth(routing: routing) else {
            return (false, nil, nil, 1, windowEventObserved)
        }
        let entry = snapshot.surfaces.first { $0.surfaceID == surfaceID }
        return (entry?.inWindow == true, entry, snapshot, 1, windowEventObserved)
    }

    func helperVisibleHealthPayload(_ snapshot: ControlSurfaceHealthSnapshot) -> JSONValue {
        .object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
            "surfaces": .array(snapshot.surfaces.map { entry in
                .object([
                    "id": .string(entry.surfaceID.uuidString),
                    "ref": ref(.surface, entry.surfaceID),
                    "type": .string(entry.typeRawValue),
                    "in_window": entry.inWindow.map { .bool($0) } ?? .null,
                ])
            }),
        ])
    }

    func helperVisibleVisibilityError(
        message: String,
        identify: HelperVisibleIdentify,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?,
        extra: [String: JSONValue]
    ) -> ControlCallResult {
        let callerWorkspaceID = uuidAny(identify.caller["workspace_id"])
        let diverged = callerWorkspaceID.map { $0 != focusedWorkspaceID } ?? false
        var data = helperVisibleFailureData(
            identify: identify,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedWindowID: focusedWindowID,
            callerFocusedDiverged: diverged
        )
        for (key, value) in extra {
            data[key] = value
        }
        return .err(code: "not_visible", message: message, data: .object(data))
    }

    private func helperVisibleCommandFailureError(
        message: String,
        identify: HelperVisibleIdentify,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?,
        extra: [String: JSONValue]
    ) -> ControlCallResult {
        let callerWorkspaceID = uuidAny(identify.caller["workspace_id"])
        let diverged = callerWorkspaceID.map { $0 != focusedWorkspaceID } ?? false
        var data = helperVisibleFailureData(
            identify: identify,
            focusedWorkspaceID: focusedWorkspaceID,
            focusedWindowID: focusedWindowID,
            callerFocusedDiverged: diverged
        )
        for (key, value) in extra {
            data[key] = value
        }
        return .err(code: "command_failed", message: message, data: .object(data))
    }

    private func helperVisibleFailureData(
        identify: HelperVisibleIdentify,
        focusedWorkspaceID: UUID,
        focusedWindowID: UUID?,
        callerFocusedDiverged: Bool
    ) -> [String: JSONValue] {
        [
            "workspace_id": .string(focusedWorkspaceID.uuidString),
            "workspace_ref": ref(.workspace, focusedWorkspaceID),
            "window_id": orNull(focusedWindowID?.uuidString),
            "window_ref": ref(.window, focusedWindowID),
            "target_workspace_source": .string("focused"),
            "caller_focused_diverged": .bool(callerFocusedDiverged),
            "focused": identify.focused.isEmpty ? .null : .object(identify.focused),
            "caller": identify.caller.isEmpty ? .null : .object(identify.caller),
        ]
    }
}
