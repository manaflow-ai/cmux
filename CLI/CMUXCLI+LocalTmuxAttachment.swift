import Foundation

extension CMUXCLI {
    func attachLocalTmuxSession(
        session: LocalTmuxSessionIdentityResolver.LiveSession,
        invocation: LocalTmuxInvocation,
        registry: LocalTmuxSessionRegistry,
        builder: LocalTmuxCommandBuilder,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let originalRecord = session.record
        let workspace = try resolveLocalTmuxWorkspace(
            invocation: invocation,
            record: originalRecord,
            client: client
        )
        let attachCommand = builder.attachCommand(binding: session.binding)
        guard workspace.id != nil || (originalRecord.workspaceID == nil && originalRecord.workspaceTitle == nil) else {
            throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
        }
        let existingSurface: String? = if !invocation.newClient,
            invocation.surface == nil,
            invocation.pane == nil,
            let workspaceID = workspace.id {
            try findExistingLocalTmuxSurface(
                workspaceID: workspaceID,
                expectedCommand: attachCommand,
                persistedSurfaceID: originalRecord.surfaceID,
                client: client
            )
        } else {
            nil
        }
        var payload: [String: Any]
        if !invocation.newClient,
           invocation.surface == nil,
           invocation.pane == nil,
           let workspaceID = workspace.id,
           let existingSurface {
            let isLive = try localTmuxSurfaceHasLiveClient(
               workspaceID: workspaceID,
               surfaceID: existingSurface,
               client: client
            )
            if isLive {
                payload = [
                    "workspace_id": workspaceID,
                    "surface_id": existingSurface,
                    "session_name": originalRecord.name,
                    "session_id": originalRecord.id.uuidString,
                    "socket_path": builder.socketPath,
                    "reattached": true,
                    "mode": "local-tmux",
                ]
                if invocation.focus ?? true {
                    let focused = try client.sendV2(method: "surface.focus", params: [
                        "workspace_id": workspaceID,
                        "surface_id": existingSurface,
                    ])
                    payload.merge(focused) { _, new in new }
                }
            } else {
                payload = try client.sendV2(method: "surface.respawn", params: [
                    "workspace_id": workspaceID,
                    "surface_id": existingSurface,
                    "command": attachCommand,
                    "initial_command": attachCommand,
                    "tmux_start_command": attachCommand,
                    "working_directory": originalRecord.cwd,
                    "focus": invocation.focus ?? true,
                ])
            }
        } else if let workspaceID = workspace.id {
            var params: [String: Any] = [
                "type": "terminal",
                "workspace_id": workspaceID,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ]
            if let paneRaw = invocation.pane,
               let paneID = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceID) {
                params["pane_id"] = paneID
            } else if let paneRaw = invocation.pane {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    "pane",
                    paneRaw
                ))
            }
            if let surfaceRaw = invocation.surface,
               let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceID) {
                params["surface_id"] = surfaceID
                params["command"] = attachCommand
                params.removeValue(forKey: "type")
                params.removeValue(forKey: "initial_command")
                payload = try client.sendV2(method: "surface.respawn", params: params)
            } else if let surfaceRaw = invocation.surface {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    "surface",
                    surfaceRaw
                ))
            } else {
                payload = try client.sendV2(method: "surface.create", params: params)
            }
        } else {
            guard invocation.pane == nil, invocation.surface == nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceRequiredForTarget", defaultValue: "local-tmux pane or surface targets require a workspace"))
            }
            var createParams: [String: Any] = [
                "title": workspace.title ?? "tmux:\(originalRecord.name)",
                "cwd": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ]
            if let windowRaw = invocation.window,
               let windowID = try normalizeWindowHandle(windowRaw, client: client) {
                createParams["window_id"] = windowID
            }
            let created = try client.sendV2(method: "workspace.create", params: createParams)
            guard let workspaceID = created["workspace_id"] as? String,
                  let surfaceID = created["surface_id"] as? String else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.workspaceCreateFailed", defaultValue: "local-tmux could not create a workspace for %@"),
                    originalRecord.name
                ))
            }
            payload = try client.sendV2(method: "surface.respawn", params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "command": attachCommand,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": invocation.focus ?? true,
            ])
            payload["workspace_id"] = workspaceID
        }

        let workspaceID = (payload["workspace_id"] as? String) ?? workspace.id
        let surfaceID = payload["surface_id"] as? String
        var updated = originalRecord
        updated.workspaceID = workspaceID
        updated.workspaceTitle = workspace.title
            ?? originalRecord.workspaceTitle
            ?? "tmux:\(originalRecord.name)"
        updated.surfaceID = surfaceID ?? originalRecord.surfaceID
        updated.updatedAt = Date.now.timeIntervalSince1970
        try registry.upsert(updated)

        payload["session_id"] = updated.id.uuidString
        payload["session_name"] = updated.name
        payload["socket_path"] = builder.socketPath
        payload["mode"] = "local-tmux"
        let fallback = String.localizedStringWithFormat(
            String(localized: "cli.localTmux.output.attached", defaultValue: "OK session=%@ surface=%@ mode=local-tmux"),
            updated.name,
            surfaceID ?? "unknown"
        )
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: fallback)
    }

    private func resolveLocalTmuxWorkspace(
        invocation: LocalTmuxInvocation,
        record: LocalTmuxSessionRecord,
        client: SocketClient
    ) throws -> (id: String?, title: String?, cwd: String?) {
        let windowID = try normalizeWindowHandle(invocation.window, client: client)
        if let rawWorkspace = invocation.workspace {
            let workspaceID = try resolveWorkspaceId(
                rawWorkspace,
                client: client,
                windowHandle: windowID
            )
            let summary = try workspaceSummary(workspaceID: workspaceID, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
            }
            return summary
        }
        if invocation.workspace == nil, invocation.window == nil,
           let caller = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] {
            let workspaceID = try resolveWorkspaceId(caller, client: client)
            let summary = try workspaceSummary(workspaceID: workspaceID, windowID: nil, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found"))
            }
            return summary
        }

        if let persistedWorkspaceID = record.workspaceID {
            let workspaceID = try resolveWorkspaceId(persistedWorkspaceID, client: client)
            let summary = try workspaceSummary(
                workspaceID: workspaceID,
                windowID: windowID,
                client: client,
                fallbackTitle: record.workspaceTitle,
                fallbackCwd: record.cwd
            )
            guard summary.id != nil else {
                return (nil, record.workspaceTitle, record.cwd)
            }
            return summary
        }

        // Titles and cwd are display/recovery hints, not identity. When an old
        // record has hints but no authoritative live workspace id, require an
        // explicit --workspace instead of attaching to a mutable lookalike.
        guard record.workspaceTitle == nil else {
            return (nil, record.workspaceTitle, record.cwd)
        }
        var currentParams: [String: Any] = [:]
        if let windowID { currentParams["window_id"] = windowID }
        if let current = try? client.sendV2(method: "workspace.current", params: currentParams),
           let workspaceID = current["workspace_id"] as? String {
            return try workspaceSummary(workspaceID: workspaceID, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
        }
        return (nil, record.workspaceTitle, record.cwd)
    }

    private func workspaceSummary(
        workspaceID: String,
        windowID: String?,
        client: SocketClient,
        fallbackTitle: String?,
        fallbackCwd: String?
    ) throws -> (id: String?, title: String?, cwd: String?) {
        let workspaces: [[String: Any]]
        if let windowID {
            let response = try client.sendV2(
                method: "workspace.list",
                params: ["window_id": windowID]
            )
            workspaces = response["workspaces"] as? [[String: Any]] ?? []
        } else {
            let windows = try client.sendV2(method: "window.list")["windows"] as? [[String: Any]] ?? []
            var allWorkspaces: [[String: Any]] = []
            for window in windows {
                guard let listedWindowID = window["id"] as? String else { continue }
                let response = try client.sendV2(
                    method: "workspace.list",
                    params: ["window_id": listedWindowID]
                )
                allWorkspaces.append(contentsOf: response["workspaces"] as? [[String: Any]] ?? [])
            }
            workspaces = allWorkspaces
        }
        if let item = workspaces.first(where: {
            guard let candidateID = $0["id"] as? String else { return false }
            return localTmuxWorkspaceIDsMatch(candidateID, workspaceID)
        }) {
            let resolvedID = item["id"] as? String ?? workspaceID
            return (resolvedID, item["title"] as? String ?? fallbackTitle, item["current_directory"] as? String ?? fallbackCwd)
        }
        return (nil, fallbackTitle, fallbackCwd)
    }

    private func localTmuxWorkspaceIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsID = UUID(uuidString: lhs), let rhsID = UUID(uuidString: rhs) {
            return lhsID == rhsID
        }
        return lhs == rhs
    }

    private func findExistingLocalTmuxSurface(
        workspaceID: String,
        expectedCommand: String,
        persistedSurfaceID: String?,
        client: SocketClient
    ) throws -> String? {
        let response = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceID])
        let surfaces = response["surfaces"] as? [[String: Any]] ?? []
        let candidates = if let persistedSurfaceID {
            surfaces.filter { ($0["id"] as? String) == persistedSurfaceID }
        } else {
            surfaces
        }
        for surface in candidates {
            let initial = surface["initial_command"] as? String ?? ""
            let start = surface["tmux_start_command"] as? String ?? ""
            guard (initial == expectedCommand || start == expectedCommand),
                  let id = surface["id"] as? String else { continue }
            return id
        }
        return nil
    }

    /// Checks the authoritative process tree before claiming a surface was
    /// reattached. A persisted marker alone can outlive a failed restore or a
    /// dead tmux client, so stale surfaces must take the respawn path.
    private func localTmuxSurfaceHasLiveClient(
        workspaceID: String,
        surfaceID: String,
        client: SocketClient
    ) throws -> Bool {
        let payload = try client.sendV2(
            method: "system.top",
            params: [
                "workspace_id": workspaceID,
                "include_processes": true,
            ],
            responseTimeout: 2.0
        )
        guard let windows = payload["windows"] as? [[String: Any]] else {
            throw CLIError(message: String(localized: "cli.localTmux.error.livenessUnavailable", defaultValue: "local-tmux could not verify the existing surface; no new client was created"))
        }
        for window in windows {
            for workspace in window["workspaces"] as? [[String: Any]] ?? [] {
                for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                    for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                        guard (surface["id"] as? String) == surfaceID else { continue }
                        return localTmuxProcessTreeContainsTmux(
                            surface["processes"] as? [[String: Any]] ?? []
                        )
                    }
                }
            }
        }
        return false
    }

    private func localTmuxProcessTreeContainsTmux(_ processes: [[String: Any]]) -> Bool {
        for process in processes {
            let name = (process["name"] as? String)?.lowercased() ?? ""
            let path = (process["path"] as? String).map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
            if name == "tmux" || name.hasPrefix("tmux:") || path == "tmux" {
                return true
            }
            if localTmuxProcessTreeContainsTmux(process["children"] as? [[String: Any]] ?? []) {
                return true
            }
        }
        return false
    }

}
