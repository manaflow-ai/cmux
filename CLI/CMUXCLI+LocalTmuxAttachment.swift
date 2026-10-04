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
        try attachLocalPersistentSession(
            record: session.record,
            attachCommand: builder.attachCommand(binding: session.binding),
            socketPath: builder.socketPath,
            request: LocalSessionAttachRequest(
                workspace: invocation.workspace,
                surface: invocation.surface,
                pane: invocation.pane,
                window: invocation.window,
                focus: invocation.focus,
                newClient: invocation.newClient
            ),
            profile: .localTmux,
            registry: registry,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    /// Attaches a cmux client surface to a durable local session, reusing a
    /// live client surface when one exists, and records where it attached.
    func attachLocalPersistentSession(
        record originalRecord: LocalTmuxSessionRecord,
        attachCommand: String,
        socketPath: String,
        request: LocalSessionAttachRequest,
        profile: LocalSessionAttachProfile,
        registry: LocalTmuxSessionRegistry,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let workspace = try resolveLocalSessionWorkspace(
            request: request,
            record: originalRecord,
            profile: profile,
            client: client
        )
        guard workspace.id != nil || (originalRecord.workspaceID == nil && originalRecord.workspaceTitle == nil) else {
            throw CLIError(message: profile.workspaceNotFound())
        }
        let existingSurface: String? = if !request.newClient,
            request.surface == nil,
            request.pane == nil,
            let workspaceID = workspace.id {
            try findExistingLocalSessionSurface(
                workspaceID: workspaceID,
                expectedCommand: attachCommand,
                persistedSurfaceID: originalRecord.surfaceID,
                client: client
            )
        } else {
            nil
        }
        var payload: [String: Any]
        if !request.newClient,
           request.surface == nil,
           request.pane == nil,
           let workspaceID = workspace.id,
           let existingSurface {
            let isLive = try localSessionSurfaceHasLiveClient(
               workspaceID: workspaceID,
               surfaceID: existingSurface,
               profile: profile,
               client: client
            )
            if isLive {
                payload = [
                    "workspace_id": workspaceID,
                    "surface_id": existingSurface,
                    "session_name": originalRecord.name,
                    "session_id": originalRecord.id.uuidString,
                    "socket_path": socketPath,
                    "reattached": true,
                    "mode": profile.mode,
                ]
                if request.focus ?? true {
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
                    "focus": request.focus ?? true,
                ])
            }
        } else if let workspaceID = workspace.id {
            var params: [String: Any] = [
                "type": "terminal",
                "workspace_id": workspaceID,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": request.focus ?? true,
            ]
            if let paneRaw = request.pane,
               let paneID = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceID) {
                params["pane_id"] = paneID
            } else if let paneRaw = request.pane {
                throw CLIError(message: profile.targetNotFound(.pane, paneRaw))
            }
            if let surfaceRaw = request.surface,
               let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceID) {
                params["surface_id"] = surfaceID
                params["command"] = attachCommand
                params.removeValue(forKey: "type")
                params.removeValue(forKey: "initial_command")
                payload = try client.sendV2(method: "surface.respawn", params: params)
            } else if let surfaceRaw = request.surface {
                throw CLIError(message: profile.targetNotFound(.surface, surfaceRaw))
            } else {
                payload = try client.sendV2(method: "surface.create", params: params)
            }
        } else {
            guard request.pane == nil, request.surface == nil else {
                throw CLIError(message: profile.workspaceRequiredForTarget())
            }
            var createParams: [String: Any] = [
                "title": workspace.title ?? "\(profile.workspaceTitlePrefix)\(originalRecord.name)",
                "cwd": originalRecord.cwd,
                "focus": request.focus ?? true,
            ]
            if let windowRaw = request.window,
               let windowID = try normalizeWindowHandle(windowRaw, client: client) {
                createParams["window_id"] = windowID
            }
            let created = try client.sendV2(method: "workspace.create", params: createParams)
            guard let workspaceID = created["workspace_id"] as? String,
                  let surfaceID = created["surface_id"] as? String else {
                throw CLIError(message: profile.workspaceCreateFailed(originalRecord.name))
            }
            payload = try client.sendV2(method: "surface.respawn", params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "command": attachCommand,
                "initial_command": attachCommand,
                "tmux_start_command": attachCommand,
                "working_directory": originalRecord.cwd,
                "focus": request.focus ?? true,
            ])
            payload["workspace_id"] = workspaceID
        }

        let workspaceID = (payload["workspace_id"] as? String) ?? workspace.id
        let surfaceID = payload["surface_id"] as? String
        var updated = originalRecord
        updated.workspaceID = workspaceID
        updated.workspaceTitle = workspace.title
            ?? originalRecord.workspaceTitle
            ?? "\(profile.workspaceTitlePrefix)\(originalRecord.name)"
        updated.surfaceID = surfaceID ?? originalRecord.surfaceID
        updated.updatedAt = Date.now.timeIntervalSince1970
        // The surface call can take a while. Update the record as it is now:
        // a close may have removed it, or a rename may have changed it.
        try registry.recordAttachment(
            id: updated.id,
            workspaceID: updated.workspaceID,
            workspaceTitle: updated.workspaceTitle,
            surfaceID: updated.surfaceID
        )

        payload["session_id"] = updated.id.uuidString
        payload["session_name"] = updated.name
        payload["socket_path"] = socketPath
        payload["mode"] = profile.mode
        let fallback = profile.attached(updated.name, surfaceID)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: fallback)
    }

    private func resolveLocalSessionWorkspace(
        request: LocalSessionAttachRequest,
        record: LocalTmuxSessionRecord,
        profile: LocalSessionAttachProfile,
        client: SocketClient
    ) throws -> (id: String?, title: String?, cwd: String?) {
        let windowID = try normalizeWindowHandle(request.window, client: client)
        if let rawWorkspace = request.workspace {
            let summary = try workspaceSummary(workspaceSelector: rawWorkspace, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: profile.workspaceNotFound())
            }
            return summary
        }
        if request.workspace == nil, request.window == nil,
           let caller = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] {
            let summary = try workspaceSummary(workspaceSelector: caller, windowID: nil, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
            guard summary.id != nil else {
                throw CLIError(message: profile.workspaceNotFound())
            }
            return summary
        }

        if let persistedWorkspaceID = record.workspaceID {
            let summary = try workspaceSummary(
                workspaceSelector: persistedWorkspaceID,
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
            return try workspaceSummary(workspaceSelector: workspaceID, windowID: windowID, client: client, fallbackTitle: record.workspaceTitle, fallbackCwd: record.cwd)
        }
        return (nil, record.workspaceTitle, record.cwd)
    }

    private func workspaceSummary(
        workspaceSelector: String,
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
            localSessionWorkspaceSelectorMatches(workspaceSelector, item: $0)
        }) {
            let resolvedID = item["id"] as? String ?? item["ref"] as? String ?? workspaceSelector
            return (resolvedID, item["title"] as? String ?? fallbackTitle, item["current_directory"] as? String ?? fallbackCwd)
        }
        return (nil, fallbackTitle, fallbackCwd)
    }

    private func localSessionWorkspaceSelectorMatches(
        _ selector: String,
        item: [String: Any]
    ) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Int(trimmed), intFromAny(item["index"]) == index {
            return true
        }
        return [item["id"] as? String, item["ref"] as? String]
            .compactMap { $0 }
            .contains { localSessionWorkspaceIDsMatch($0, trimmed) }
    }

    private func localSessionWorkspaceIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsID = UUID(uuidString: lhs), let rhsID = UUID(uuidString: rhs) {
            return lhsID == rhsID
        }
        return lhs == rhs
    }

    private func findExistingLocalSessionSurface(
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
    /// dead multiplexer client, so stale surfaces must take the respawn path.
    private func localSessionSurfaceHasLiveClient(
        workspaceID: String,
        surfaceID: String,
        profile: LocalSessionAttachProfile,
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
            throw CLIError(message: profile.livenessUnavailable())
        }
        var surfaceProcesses: [[String: Any]]?
        for window in windows {
            for workspace in window["workspaces"] as? [[String: Any]] ?? [] {
                for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                    for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                        guard (surface["id"] as? String) == surfaceID else { continue }
                        surfaceProcesses = surface["processes"] as? [[String: Any]] ?? []
                        break
                    }
                    if surfaceProcesses != nil { break }
                }
                if surfaceProcesses != nil { break }
            }
            if surfaceProcesses != nil { break }
        }
        guard let surfaceProcesses else {
            throw CLIError(message: profile.livenessUnavailable())
        }
        return localSessionProcessTree(surfaceProcesses, contains: profile.clientProcessName)
    }

    private func localSessionProcessTree(
        _ processes: [[String: Any]],
        contains clientProcessName: String
    ) -> Bool {
        for process in processes {
            let name = (process["name"] as? String)?.lowercased() ?? ""
            let path = (process["path"] as? String).map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
            if name == clientProcessName || name.hasPrefix("\(clientProcessName):") || path == clientProcessName {
                return true
            }
            if localSessionProcessTree(process["children"] as? [[String: Any]] ?? [], contains: clientProcessName) {
                return true
            }
        }
        return false
    }

}
