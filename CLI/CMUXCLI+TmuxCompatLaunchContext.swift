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
        // A managed launcher is anchored to the immutable identity injected into its
        // terminal. Without either inherited key there is no caller to validate, so fail
        // closed before opening the socket. In particular, never borrow system-wide focus
        // from `system.identify`: a command started in Terminal.app must not target an
        // unrelated cmux surface merely because that surface happens to be focused.
        let ownWorkspace = normalizedTmuxTarget(processEnvironment["CMUX_WORKSPACE_ID"])
        let ownSurface = normalizedTmuxTarget(processEnvironment["CMUX_SURFACE_ID"])
        guard ownWorkspace != nil || ownSurface != nil else { return nil }

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
                return try contextFromSurfacePayload(
                    payload,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    surfaceHandle: surfaceHandle,
                    windowHandle: windowHandle
                )
            }

            func contextFromSurfacePayload(
                _ payload: [String: Any],
                workspaceId: String,
                surfaceId: String,
                surfaceHandle: String,
                windowHandle: String?
            ) throws -> TmuxCompatLaunchContext {
                let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
                let normalizedSurfaceHandle = tmuxTrimIdSigil(surfaceHandle)
                guard let surface = surfaces.first(where: {
                    ($0["id"] as? String) == surfaceId
                        || ($0["ref"] as? String) == normalizedSurfaceHandle
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
            // workspace/surface pair. Resolve and validate it without consulting global focus, so
            // switching or closing the operator's focused pane cannot retarget a running team.
            // Once either component is present, the inherited pair is authoritative: an incomplete
            // or stale pair fails closed instead of silently changing identity to the focused pane.
            if let ownWorkspace, let ownSurface {
                if let context = try? contextFromSurface(
                    workspaceHandle: ownWorkspace,
                    surfaceHandle: ownSurface,
                    windowHandle: nil
                ) {
                    return context
                }
            }

            // A surface's stable UUID survives moves between workspaces. The inherited
            // workspace can therefore be stale while the launch surface is still live.
            // Relocate that UUID from structured socket state without consulting global
            // focus; an inherited identity must never silently retarget to another surface.
            guard let ownSurface else { return nil }
            let surfaceId = tmuxTrimIdSigil(ownSurface)
            guard isUUID(surfaceId) else { return nil }
            let payload = try client.sendV2(
                method: "surface.list",
                params: ["surface_id": surfaceId]
            )
            guard let currentWorkspaceId = payload["workspace_id"] as? String,
                  isUUID(currentWorkspaceId) else {
                return nil
            }
            return try? contextFromSurfacePayload(
                payload,
                workspaceId: currentWorkspaceId,
                surfaceId: surfaceId,
                surfaceHandle: surfaceId,
                windowHandle: nil
            )
        } catch {
            client.close()
            return nil
        }
    }

    func createClaudeTeamsShimDirectory(
        processEnvironment: [String: String],
        commandArgs: [String]
    ) throws -> URL {
        let downstreamTmuxMissing = String(
            localized: "cli.tmux-compat.error.downstreamTmuxMissing",
            defaultValue: "cmux tmux shim: no downstream tmux executable found"
        )
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ -n "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-}" ]]; then
          exec "$CMUX_CLAUDE_TEAMS_CMUX_BIN" __tmux-compat "$@"
        fi

        # This shim lives in a persistent per-surface PATH directory. Outside the
        # claude-teams launch it must behave transparently, even when several cmux
        # shim directories are present. Remove every PATH spelling of this shim's
        # directory before resolving tmux; the next shim repeats the narrowing.
        shim_dir="$(cd -P -- "$(dirname -- "$0")" && pwd)"
        IFS=: read -r -a path_entries <<< "${PATH-}"
        filtered_path=""
        has_filtered_entry=0
        for path_entry in "${path_entries[@]}"; do
          resolved_dir="$(cd -P -- "${path_entry:-.}" 2>/dev/null && pwd)" || resolved_dir=""
          if [[ "$resolved_dir" == "$shim_dir" ]]; then
            continue
          fi
          if (( has_filtered_entry )); then
            filtered_path+=":$path_entry"
          else
            filtered_path="$path_entry"
            has_filtered_entry=1
          fi
        done
        PATH="$filtered_path"
        export PATH
        next_tmux="$(type -P tmux || true)"
        if [[ -z "$next_tmux" ]]; then
          echo \(tmuxShellQuote(downstreamTmuxMissing)) >&2
          exit 127
        fi
        exec "$next_tmux" "$@"
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
            let temporaryRoot = normalizedTmuxTarget(processEnvironment["TMPDIR"])
                .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
                ?? FileManager.default.temporaryDirectory.standardizedFileURL
            let managedBase = temporaryRoot
                .appendingPathComponent("cmux-cli-shims", isDirectory: true)
                .standardizedFileURL
            if managedRoot.deletingLastPathComponent() == managedBase,
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
                    // Informational launches do not create teammates, so they may use the
                    // launcher-only compatibility directory below. Real Teams sessions must
                    // keep tmux in Claude's managed snapshot PATH.
                }
            }
        }

        guard tmuxCompatIsInformationalInvocation(commandArgs: commandArgs) else {
            throw CLIError(message: managedTerminalRequiredMessage(displayName: "Claude Teams"))
        }
        return try createTmuxCompatShimDirectory(
            directoryName: "claude-teams-bin",
            tmuxShimScript: script
        )
    }
}
