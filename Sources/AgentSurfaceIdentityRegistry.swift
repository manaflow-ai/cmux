import Foundation

/// Maps an agent-minted token to the surface whose output stream announced it.
///
/// Hooks need a surface to address, and `CMUX_SURFACE_ID` cannot supply one in
/// two common cases: shell integration deliberately clears it inside tmux
/// (identity inherited through a daemonized tmux server would be stale), and it
/// never survives SSH. Guessing from the focused surface is wrong -- a
/// background agent finishing would mis-deliver onto whatever pane the user
/// happens to be looking at.
///
/// Instead the agent announces itself: the launch wrapper mints a token, emits
/// it as an OSC 777 with a reserved title, and exports it into the agent's
/// environment. Ghostty attributes that sequence to the surface whose stream
/// carried it, so the announcement arrives already bound to the right surface
/// with no identity to inherit and nothing to go stale. Hooks then address the
/// socket by token.
///
/// This is deliberately one-way. A query/response handshake would have to write
/// a reply into the terminal, which any program reading the tty could observe
/// or be corrupted by; an announcement discloses nothing to the far side.
final class AgentSurfaceIdentityRegistry {
    static let shared = AgentSurfaceIdentityRegistry()

    /// Reserved OSC 777 title. A notification carrying it is an identity
    /// announcement, not a user-visible message, and is never displayed.
    static let announcementTitle = "cmux.agent.identity"

    struct Binding {
        let tabId: UUID
        let surfaceId: UUID
        let announcedAt: Date
    }

    /// A token is minted per agent launch. Bindings are pruned on access
    /// rather than on a timer: the map is small, and a timer would keep the app
    /// awake for no benefit.
    private var bindings: [String: Binding] = [:]
    private let lock = NSLock()

    /// Bounds the map if an agent relaunches repeatedly.
    private let maximumBindings = 512

    /// A binding outlives its usefulness once the agent that announced it is
    /// gone, and nothing tells this registry when a surface closes. Expiring on
    /// access bounds the staleness window without needing that signal: an
    /// agent session far older than this is not one whose hooks are still
    /// firing, and resolving a recycled token onto a dead pane would be worse
    /// than failing closed.
    private let bindingLifetime: TimeInterval = 24 * 60 * 60

    private init() {}

    /// Records that `token` belongs to the surface that emitted the
    /// announcement. A repeated announcement for the same token refreshes it:
    /// an agent may re-announce after a resume, and the newest stream wins.
    func record(token: String, tabId: UUID, surfaceId: UUID, now: Date = Date()) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        bindings[trimmed] = Binding(tabId: tabId, surfaceId: surfaceId, announcedAt: now)
        guard bindings.count > maximumBindings else { return }
        let overflow = bindings.count - maximumBindings
        for key in bindings
            .sorted(by: { $0.value.announcedAt < $1.value.announcedAt })
            .prefix(overflow)
            .map(\.key) {
            bindings.removeValue(forKey: key)
        }
    }

    /// Returns the surface that announced `token`, or nil when the token was
    /// never announced. Callers must treat nil as "do not guess": delivering to
    /// a fallback surface is the mis-routing this registry exists to prevent.
    func binding(for token: String, now: Date = Date()) -> Binding? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let binding = bindings[trimmed] else { return nil }
        guard now.timeIntervalSince(binding.announcedAt) <= bindingLifetime else {
            bindings.removeValue(forKey: trimmed)
            return nil
        }
        return binding
    }
}

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
    func v2AgentIdentityResolve(params: [String: Any]) -> V2CallResult {
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
        return .ok([
            "workspace_id": binding.tabId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: binding.tabId),
            "surface_id": binding.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: binding.surfaceId),
        ])
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
        // A binding can outlive its workspace: the agent keeps running in a
        // remote tmux session while the workspace that carried its
        // announcement is closed or the app restarts. Running the hook against
        // the dead IDs would silently no-op every mutation, so report
        // not_found instead — the remote daemon answers it by re-announcing
        // the token on the pane's current stream, which rebinds it.
        let workspaceAlive = v2MainSync {
            AppDelegate.shared?.tabManagerFor(tabId: binding.tabId) != nil
        }
        guard workspaceAlive else {
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
        environment["CMUX_WORKSPACE_ID"] = binding.tabId.uuidString
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
            "workspace_id": binding.tabId.uuidString,
        ])
    }

    private static let allowedHookAgents: Set<String> = ["claude"]

    /// Mirrors the events the launch wrapper installs in its hook settings.
    private static let allowedHookEvents: Set<String> = [
        "session-start", "session-end", "stop", "notification", "prompt-submit",
        "pre-tool-use", "push-notification", "auto-name", "cron-create-guard",
    ]
}
