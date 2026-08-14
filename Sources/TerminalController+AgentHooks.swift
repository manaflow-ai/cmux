import Foundation

/// The control-socket handlers for agent-hook identity: `agent.identity.resolve`
/// and `agent.hook.run`. Split from `AgentSurfaceIdentityRegistry.swift` so the
/// registry file holds only the token store; controller socket handlers live in
/// `TerminalController+<Feature>.swift` files by convention.
extension TerminalController {
    /// `agent.identity.resolve` — map an announced agent token to the surface
    /// whose output stream carried the announcement.
    ///
    /// Hooks call this when the environment cannot identify their surface,
    /// which is the normal case inside tmux and across SSH. It is deliberately
    /// fail-closed: an unknown token is an error, never a fallback to the
    /// focused surface, because delivering a background agent's turn onto
    /// whatever pane the user is looking at is the exact mis-routing the
    /// announcement mechanism exists to prevent.
    nonisolated func v2AgentIdentityResolve(params: [String: Any]) -> V2CallResult {
        guard let token = v2RawString(params, "token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty else {
            return .err(code: "invalid_params", message: "token is required", data: nil)
        }
        guard let binding = AgentSurfaceIdentityRegistry.shared.binding(for: token) else {
            return .err(
                code: "not_found",
                message: "No surface announced this token",
                data: nil
            )
        }
        guard let ownerTabId = currentOwnerTabId(of: binding) else {
            return .err(code: "not_found", message: "Announced surface is gone", data: nil)
        }
        return .ok([
            "workspace_id": ownerTabId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ownerTabId),
            "surface_id": binding.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: binding.surfaceId),
        ])
    }

    /// The workspace that owns the announced surface NOW. The binding records
    /// the workspace at announcement time, which goes stale when the user
    /// drags the pane to another workspace or the workspace is recycled;
    /// hooks must follow the pane the way the env/pid delivery probes already
    /// do. Nil when the surface no longer exists anywhere — the caller
    /// reports not_found, and the remote daemon answers that by re-announcing
    /// on the pane's current stream.
    private nonisolated func currentOwnerTabId(
        of binding: AgentSurfaceIdentityRegistry.Binding
    ) -> UUID? {
        v2MainSync {
            AppDelegate.shared?.workspaceContainingPanel(
                panelId: binding.surfaceId,
                preferredWorkspaceId: binding.tabId
            )?.workspace.id
        }
    }

    /// `agent.hook.run` — run one agent hook here, for a surface identified by
    /// an announced token, and return what the hook wrote to stdout.
    ///
    /// A remote host runs the agent but has no copy of this CLI: `cmux` there
    /// is the cmuxd-remote Go binary. Rather than reimplementing eight hook
    /// behaviors in Go -- a port that would drift from this one forever -- the
    /// remote daemon forwards the invocation and the Mac runs the very same
    /// executable it would have run locally, with the resolved surface injected
    /// into the environment. Every hook therefore behaves identically whether
    /// the agent is local or across an SSH relay.
    /// Nonisolated on purpose: it blocks on a child process, so it must run on
    /// the socket worker rather than hopping onto the main actor. It touches
    /// only the lock-guarded registry, Bundle, and Process.
    nonisolated func v2AgentHookRun(params: [String: Any]) -> V2CallResult {
        guard let token = v2RawString(params, "token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty else {
            return .err(code: "invalid_params", message: "token is required", data: nil)
        }
        guard let agent = v2RawString(params, "agent")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            Self.allowedHookAgents.contains(agent) || agent == "feed" else {
            return .err(code: "invalid_params", message: "unsupported agent", data: nil)
        }
        guard let event = v2RawString(params, "event")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !event.isEmpty else {
            return .err(code: "invalid_params", message: "event is required", data: nil)
        }
        // Allowlisted rather than forwarded verbatim: this argv is built from
        // input that crossed the relay, and must never become a way to run an
        // arbitrary subcommand on the user's Mac. The feed lane reuses the
        // `event` parameter to carry its --source agent so the RPC shape stays
        // fixed; that source is held to the same agent allowlist.
        let arguments: [String]
        if agent == "feed" {
            guard Self.allowedHookAgents.contains(event) else {
                return .err(code: "invalid_params", message: "unsupported feed source", data: nil)
            }
            arguments = ["hooks", "feed", "--source", event]
        } else {
            guard Self.allowedHookEvents.contains(event) else {
                return .err(code: "invalid_params", message: "unsupported event", data: nil)
            }
            arguments = ["hooks", agent, event]
        }
        guard let binding = AgentSurfaceIdentityRegistry.shared.binding(for: token) else {
            return .err(code: "not_found", message: "No surface announced this token", data: nil)
        }
        // Resolve the surface's CURRENT owner: the recorded workspace goes
        // stale when the pane is dragged elsewhere or its workspace is
        // recycled while the agent keeps running. Running the hook against
        // dead IDs would silently no-op every mutation, so a gone surface is
        // not_found — the remote daemon answers that by re-announcing the
        // token on the pane's current stream, which rebinds it.
        guard let ownerTabId = currentOwnerTabId(of: binding) else {
            return .err(code: "not_found", message: "Announced surface is gone", data: nil)
        }
        guard let cliURL = Bundle.main.resourceURL?
            .appendingPathComponent("bin/cmux", isDirectory: false),
            FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return .err(code: "unavailable", message: "Bundled cmux CLI not found", data: nil)
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SURFACE_ID"] = binding.surfaceId.uuidString
        environment["CMUX_WORKSPACE_ID"] = ownerTabId.uuidString
        // The hook is already running on behalf of a remote agent; do not let a
        // stale local token re-enter and re-resolve to a different surface.
        environment.removeValue(forKey: "CMUX_AGENT_HOOK_TOKEN")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .err(code: "unavailable", message: "Could not run hook", data: nil)
        }
        let stdinPayload = v2RawString(params, "stdin") ?? ""
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdinPayload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return .ok([
            "stdout": String(data: outputData, encoding: .utf8) ?? "",
            "exit_code": Int(process.terminationStatus),
            "surface_id": binding.surfaceId.uuidString,
            "workspace_id": ownerTabId.uuidString,
        ])
    }

    private static let allowedHookAgents: Set<String> = ["claude"]

    /// Mirrors the events the launch wrapper installs in its hook settings.
    private static let allowedHookEvents: Set<String> = [
        "session-start", "session-end", "stop", "notification", "prompt-submit",
        "pre-tool-use", "push-notification", "auto-name", "cron-create-guard",
    ]
}
