internal import Foundation

/// The authenticated `surface.report_tty` write path. Kept separate because
/// remote reports carry terminal-runtime identity in addition to surface scope.
extension ControlCommandCoordinator {
    func surfaceReportTTY(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workspaceID = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedSurfaceID = uuid(params, "surface_id")
        if hasNonNull(params, "surface_id"), requestedSurfaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let ttyName = rawString(params, "tty_name")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing tty_name", data: nil)
        }

        let authenticatedRemoteWorkspaceID = string(
            params,
            "_cmux_remote_workspace_id"
        ).flatMap(UUID.init(uuidString:))
        let terminalLifecycleID = string(params, "terminal_lifecycle_id")
            .flatMap(UUID.init(uuidString:))
        let attemptID = string(params, "attempt_id").flatMap(UUID.init(uuidString:))
        for (key, value) in [
            ("_cmux_remote_workspace_id", authenticatedRemoteWorkspaceID),
            ("terminal_lifecycle_id", terminalLifecycleID),
            ("attempt_id", attemptID),
        ] where hasNonNull(params, key) && value == nil {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid \(key)",
                data: nil
            )
        }

        let resolution = context?.controlSurfaceReportTTY(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID,
            ttyName: ttyName,
            authenticatedRemoteWorkspaceID: authenticatedRemoteWorkspaceID,
            terminalLifecycleID: terminalLifecycleID,
            attemptID: attemptID
        ) ?? .workspaceNotFound
        let requestedSurfaceData = surfaceReportSurfaceFields(
            workspaceID: workspaceID,
            requestedSurfaceID: requestedSurfaceID
        )
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: .object(requestedSurfaceData))
        case .surfaceNotFound:
            return .err(code: "not_found", message: "Surface not found", data: .object(requestedSurfaceData))
        case .pending:
            var payload = requestedSurfaceData
            payload["tty_name"] = .string(ttyName)
            payload["pending"] = .bool(true)
            return .ok(.object(payload))
        case .recorded(let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "tty_name": .string(ttyName),
            ]))
        }
    }
}
