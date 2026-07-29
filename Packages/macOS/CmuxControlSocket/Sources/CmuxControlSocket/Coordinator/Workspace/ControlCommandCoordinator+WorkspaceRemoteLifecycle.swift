internal import Foundation

extension ControlCommandCoordinator {
    /// `workspace.remote.terminal_session_connected` — record the terminal's
    /// successful SSH/PTY handshake independently of auxiliary proxy state.
    ///
    /// Persistent lifecycle authentication stays on the socket worker because
    /// the broker owns that state on its serial queue. Only the authenticated
    /// authority snapshot crosses the command's single main-actor mutation hop.
    nonisolated func workspaceRemoteTerminalSessionConnected(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let workspaceID = string(params, "workspace_id").flatMap(UUID.init(uuidString:)) else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceID = string(params, "surface_id").flatMap(UUID.init(uuidString:)) else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let relayPort = strictInt(params, "relay_port")
        let sessionID = optionalTrimmedRawString(params, "session_id")
        let lifecycleID = optionalTrimmedRawString(params, "lifecycle_id")
        let invalidRelayPort = relayPort.map { $0 <= 0 || $0 > 65535 } ?? false
        let hasRelayAuthority = relayPort != nil
        let hasPersistentAuthority = sessionID != nil && lifecycleID != nil
        if invalidRelayPort ||
            (params["relay_port"] != nil && relayPort == nil) ||
            (sessionID == nil) != (lifecycleID == nil) ||
            hasRelayAuthority == hasPersistentAuthority {
            return .err(
                code: "invalid_params",
                message: "Provide exactly one terminal authority: relay_port or session_id with lifecycle_id",
                data: nil
            )
        }

        guard let context else {
            return .err(code: "unavailable", message: "Workspace context not available", data: nil)
        }
        let authority: ControlWorkspaceRemoteTerminalAuthority?
        if let relayPort {
            authority = .relayPort(relayPort)
        } else if let sessionID,
                  let lifecycleID,
                  let owner = context.controlCurrentRemotePTYLifecycleOwner(
                      sessionID: sessionID,
                      lifecycleID: lifecycleID
                  ),
                  owner.attachmentID == surfaceID.uuidString {
            authority = .persistentTransport(owner.transportKey)
        } else {
            authority = nil
        }

        return context.controlResolveOnMain { seam in
            let resolution = authority.map {
                seam.controlWorkspaceRemoteTerminalSessionConnected(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    authority: $0
                )
            } ?? .notFound
            switch resolution {
            case .notFound:
                return .err(code: "not_found", message: "Workspace not found", data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "workspace_ref": self.ref(.workspace, workspaceID),
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": self.ref(.surface, surfaceID),
                    "relay_port": relayPort.map { .int(Int64($0)) } ?? .null,
                ]))
            case .resolved(let windowID, let resolvedWorkspaceID, let remoteStatus):
                return .ok(.object([
                    "window_id": self.orNull(windowID?.uuidString),
                    "window_ref": self.ref(.window, windowID),
                    "workspace_id": self.orNull(resolvedWorkspaceID?.uuidString),
                    "workspace_ref": self.ref(.workspace, resolvedWorkspaceID),
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": self.ref(.surface, surfaceID),
                    "relay_port": relayPort.map { .int(Int64($0)) } ?? .null,
                    "remote": remoteStatus,
                ]))
            }
        }
    }

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
                "workspace_id": orNull(resolvedWorkspaceID?.uuidString),
                "workspace_ref": ref(.workspace, resolvedWorkspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "relay_port": relayPort.map { .int(Int64($0)) } ?? .null,
                "remote": remoteStatus,
            ]))
        }
    }
}
