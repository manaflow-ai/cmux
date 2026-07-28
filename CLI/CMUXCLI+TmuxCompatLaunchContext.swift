import Foundation

private enum TmuxCompatLaunchContextError: Error {
    case launchSurfaceHasNoPane
}

extension CMUXCLI {
    struct TmuxCompatLaunchContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }

    func tmuxCompatResolvedSocketPath(processEnvironment: [String: String]) throws -> String {
        let envSocketPath = try CLISocketEnvironment.socketPath(in: processEnvironment)
        let bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: processEnvironment
        )
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(
                envSocketPath,
                bundleIdentifier: bundleIdentifier,
                environment: processEnvironment
            ) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }
        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }

    func tmuxCompatLaunchContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) throws -> TmuxCompatLaunchContext? {
        let socketPath = try tmuxCompatResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            func contextFromSurface(
                workspaceHandle: String,
                surfaceHandle: String,
                windowHandle: String?
            ) throws -> TmuxCompatLaunchContext {
                let workspaceId = try resolveWorkspaceId(workspaceHandle, client: client)
                let surfaceToken = tmuxTrimIdSigil(surfaceHandle)
                let surfaceId = isUUID(surfaceToken)
                    ? surfaceToken
                    : try tmuxCanonicalSurfaceId(surfaceHandle, workspaceId: workspaceId, client: client)
                let payload = try client.sendV2(
                    method: "surface.list",
                    params: ["workspace_id": workspaceId]
                )
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                guard let surface = surfaces.first(where: {
                    ($0["id"] as? String) == surfaceId || ($0["ref"] as? String) == surfaceHandle
                }),
                let rawPaneHandle = (surface["pane_id"] as? String) ?? (surface["pane_ref"] as? String) else {
                    throw TmuxCompatLaunchContextError.launchSurfaceHasNoPane
                }
                let paneHandle = rawPaneHandle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !paneHandle.isEmpty else {
                    throw TmuxCompatLaunchContextError.launchSurfaceHasNoPane
                }
                let paneId = try? tmuxCanonicalPaneId(
                    paneHandle,
                    workspaceId: workspaceId,
                    client: client
                )
                let windowId = (payload["window_id"] as? String)
                    ?? (payload["window_ref"] as? String)
                    ?? windowHandle
                return TmuxCompatLaunchContext(
                    socketPath: socketPath,
                    workspaceId: workspaceId,
                    windowId: windowId,
                    paneHandle: paneHandle,
                    paneId: paneId,
                    surfaceId: surfaceId
                )
            }

            // A launcher running inside a cmux terminal inherits that surface's immutable
            // workspace/surface pair. Resolve and validate it before consulting global focus, so
            // switching or closing the operator's focused pane cannot retarget a running team.
            if let ownWorkspace = normalizedTmuxTarget(processEnvironment["CMUX_WORKSPACE_ID"]),
               let ownSurface = normalizedTmuxTarget(processEnvironment["CMUX_SURFACE_ID"]),
               let ownContext = try? contextFromSurface(
                   workspaceHandle: ownWorkspace,
                   surfaceHandle: ownSurface,
                   windowHandle: nil
               ) {
                return ownContext
            }

            let payload = try client.sendV2(method: "system.identify")
            let focused = payload["focused"] as? [String: Any] ?? [:]
            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["pane_id"] as? String)
                ?? (focused["pane_ref"] as? String)
            guard let workspaceId, let paneId else { return nil }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else { return nil }

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["surface_id"] as? String)
                ?? (focused["surface_ref"] as? String)
            if let surfaceId,
               let focusedContext = try? contextFromSurface(
                   workspaceHandle: workspaceId,
                   surfaceHandle: surfaceId,
                   windowHandle: windowId
               ) {
                return focusedContext
            }

            let canonicalPaneId: String? = {
                guard let canonicalWorkspaceId = try? resolveWorkspaceId(workspaceId, client: client) else {
                    return nil
                }
                if let paneUUID = normalizedTmuxTarget(focused["pane_uuid"] as? String) {
                    return paneUUID
                }
                if let paneId = normalizedTmuxTarget(focused["pane_id"] as? String),
                   let canonical = try? tmuxCanonicalPaneId(
                       paneId,
                       workspaceId: canonicalWorkspaceId,
                       client: client
                   ) {
                    return canonical
                }
                return try? tmuxCanonicalPaneId(
                    paneHandle,
                    workspaceId: canonicalWorkspaceId,
                    client: client
                )
            }()

            return TmuxCompatLaunchContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: canonicalPaneId,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

    func createClaudeTeamsShimDirectory(processEnvironment: [String: String]) throws -> URL {
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """

        // Claude Code can replace PATH with a shell snapshot after launch. Its snapshot keeps
        // cmux's managed per-surface command-shim directory, so install tmux beside the existing
        // claude shim instead of relying on a separate launcher-only PATH entry. Validate both
        // managed paths before writing; environment variables alone must not select an arbitrary
        // user directory as an overwrite target.
        if let rawRoot = normalizedTmuxTarget(processEnvironment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"]),
           let rawClaudeShim = normalizedTmuxTarget(processEnvironment["CMUX_CLAUDE_WRAPPER_SHIM"]) {
            let managedRoot = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
            let claudeShim = URL(fileURLWithPath: rawClaudeShim, isDirectory: false).standardizedFileURL
            if managedRoot.deletingLastPathComponent().lastPathComponent == "cmux-cli-shims",
               claudeShim.deletingLastPathComponent() == managedRoot,
               claudeShim.lastPathComponent == "claude",
               FileManager.default.isExecutableFile(atPath: claudeShim.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: managedRoot,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try writeShimIfChanged(
                        script,
                        to: managedRoot.appendingPathComponent("tmux", isDirectory: false)
                    )
                    return managedRoot
                } catch {
                    // A stale or read-only per-surface directory should not block teams launch;
                    // retain the stable home-directory shim as the compatibility fallback.
                }
            }
        }
        return try createTmuxCompatShimDirectory(
            directoryName: "claude-teams-bin",
            tmuxShimScript: script
        )
    }
}
