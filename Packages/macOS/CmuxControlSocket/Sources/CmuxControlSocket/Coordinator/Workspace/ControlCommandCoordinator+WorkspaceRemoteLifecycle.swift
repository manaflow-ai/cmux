internal import Foundation

extension ControlCommandCoordinator {
    /// `workspace.remote.terminal_session_end` — retire any persistent PTY
    /// generation owned by the wrapper, then optionally record terminal end.
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
        let sessionID = optionalTrimmedRawString(params, "session_id")
        let lifecycleID = optionalTrimmedRawString(params, "lifecycle_id")
        let lifecycleOnly = (bool(params, "lifecycle_only") ?? false) && sessionID != nil && lifecycleID != nil

        let resolution = context?.controlWorkspaceRemoteTerminalSessionEnd(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            relayPort: relayPort,
            sessionID: sessionID,
            lifecycleID: lifecycleID,
            lifecycleOnly: lifecycleOnly
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
}
