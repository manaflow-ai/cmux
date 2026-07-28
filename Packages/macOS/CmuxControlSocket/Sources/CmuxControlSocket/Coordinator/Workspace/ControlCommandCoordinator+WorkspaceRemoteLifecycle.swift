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
        let sessionID = optionalTrimmedRawString(params, "session_id")
        let lifecycleID = optionalTrimmedRawString(params, "lifecycle_id")
        let lifecycleOnly = bool(params, "lifecycle_only") ?? false
        if lifecycleOnly, sessionID == nil || lifecycleID == nil {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let relayPort = strictInt(params, "relay_port")
        let invalidRelayPort = relayPort.map { $0 <= 0 || $0 > 65535 } ?? false
        if invalidRelayPort || (params["relay_port"] != nil && relayPort == nil) || (!lifecycleOnly && relayPort == nil) {
            return .err(code: "invalid_params", message: "Missing or invalid relay_port", data: nil)
        }

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
                "relay_port": relayPort.map { .int(Int64($0)) } ?? .null,
            ]))
        case .resolved(let windowID, let resolvedWorkspaceID, let remoteStatus):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(resolvedWorkspaceID.uuidString),
                "workspace_ref": ref(.workspace, resolvedWorkspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "relay_port": relayPort.map { .int(Int64($0)) } ?? .null,
                "remote": remoteStatus,
            ]))
        }
    }
}
