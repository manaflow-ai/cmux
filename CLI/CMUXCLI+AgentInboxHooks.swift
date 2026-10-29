import Foundation

/// Agent inbox delivery through Claude, Codex, and Kiro hook protocols.
extension CMUXCLI {
    // MARK: - Hooks

    /// Handles `hooks <claude|codex|kiro> inbox-*`. Returns false for any other
    /// hook subcommand. Every path fails open: a missing surface, a disabled
    /// integration or a socket error prints the agent's no-op answer. Kiro's
    /// no-op answer is empty output, because Kiro adds a prompt-submit hook's
    /// stdout to the model context.
    func runAgentInboxHookIfMatched(
        agent: String,
        commandArgs: [String],
        client: SocketClient
    ) throws -> Bool {
        guard let subcommand = commandArgs.first?.lowercased(),
              subcommand.hasPrefix("inbox-") else { return false }
        let env = ProcessInfo.processInfo.environment
        let input = Self.agentInboxHookInput()
        let disabledKey = "CMUX_\(agent.uppercased())_HOOKS_DISABLED"
        let kiroPID = agent == "kiro"
            ? (kiroCLIAncestorPID() ?? agentPIDFromHookEnvironment(agentName: agent, env: env))
            : nil
        let isGlobalKiroHook = agent == "kiro" && env["CMUX_KIRO_GLOBAL_HOOK"] == "1"
        // Headless `claude -p`, `codex exec` and `kiro-cli chat --no-interactive`
        // runs share the pane's surface id with the interactive session there;
        // they must not claim its messages.
        let headlessKey: String? = switch agent {
        case "claude": "CMUX_CLAUDE_HEADLESS"
        case "codex": "CMUX_CODEX_HEADLESS"
        default: nil
        }
        let headless = headlessKey.map { env[$0] == "1" } ?? (agent == "kiro" && kiroHookIsHeadlessOrNested())
        guard let surfaceId = env["CMUX_SURFACE_ID"], !surfaceId.isEmpty, env[disabledKey] != "1", !headless else {
            if subcommand != "inbox-wait", agent != "kiro" { print("{}") }
            return true
        }
        if isGlobalKiroHook,
           let kiroPID,
           !kiroHookMatchesActiveSurface(surfaceId: surfaceId, pid: kiroPID, client: client) {
            return true
        }
        if isGlobalKiroHook, kiroPID == nil {
            return true
        }
        switch (agent, subcommand) {
        case ("kiro", "inbox-drain"):
            // Kiro adds this stdout to the context of the prompt just sent.
            let text = Self.agentInboxClaim(
                surfaceId: surfaceId,
                via: "kiro.prompt-submit",
                markDeliveredRead: false,
                agentPID: kiroPID,
                client: client
            )
            if !text.isEmpty { print(text) }
        case ("kiro", "inbox-stop"):
            // Kiro Stop: `decision: block` starts another turn with the reason.
            let text = Self.agentInboxClaim(
                surfaceId: surfaceId,
                via: "kiro.stop",
                markDeliveredRead: true,
                agentPID: kiroPID,
                client: client
            )
            if !text.isEmpty { print(Self.agentInboxStopOutput(text: text)) }
        case ("kiro", _):
            break
        case ("claude", "inbox-wait"):
            runClaudeInboxWait(surfaceId: surfaceId, input: input, client: client, env: env)
        case (_, "inbox-drain"):
            // UserPromptSubmit: attach pending messages to the prompt the
            // human just sent.
            let text = Self.agentInboxClaim(
                surfaceId: surfaceId,
                via: "\(agent).prompt-submit",
                markDeliveredRead: false,
                agentPID: nil,
                client: client
            )
            print(Self.agentInboxPromptSubmitOutput(text: text))
        case ("codex", "inbox-stop"):
            // Codex Stop: continue the turn with pending messages instead of
            // going idle. Codex can't be woken once idle.
            let text = Self.agentInboxClaim(
                surfaceId: surfaceId,
                via: "codex.stop",
                markDeliveredRead: true,
                agentPID: nil,
                client: client
            )
            print(Self.agentInboxStopOutput(text: text))
        default:
            print("{}")
        }
        fflush(stdout)
        return true
    }

    /// Confirms that a live Kiro process still resolves to the hook's surface.
    /// The surface id is inherited by child processes, so it is not sufficient
    /// on its own to identify the active Kiro session.
    private func kiroHookMatchesActiveSurface(
        surfaceId: String,
        pid: Int,
        client: SocketClient
    ) -> Bool {
        guard let result = try? client.sendV2(
            method: "agent.resolve_delivery_target",
            params: ["pid": pid, "pid_resolution": "corroborated"],
            responseTimeout: 1
        ),
        result["surface_id"] as? String == surfaceId else {
            return false
        }
        return true
    }

    /// Claude SessionStart/Stop `asyncRewake` hook. Checks for messages to
    /// this surface every ``agentInboxPollInterval``; when one is waiting it
    /// claims it, writes it to stderr and exits 2, which wakes Claude with the
    /// text as a system reminder. The prompt box, and any draft in it, is
    /// never touched.
    ///
    /// Each check uses a new connection that is closed right after, so an
    /// idle session never holds one of the app's socket connection slots.
    /// Every Stop starts a new hook; the newest registers as the surface's
    /// poller and the older ones exit when told they are superseded.
    private func runClaudeInboxWait(
        surfaceId: String,
        input: [String: Any],
        client: SocketClient,
        env: [String: String]
    ) -> Never {
        let hookEvent = input["hook_event_name"] as? String
        let isStop = hookEvent == "Stop" || hookEvent == "StopFailure"
        let agentPID = env["CMUX_CLAUDE_PID"].flatMap { Int32($0) }
        let pollerKey = UUID().uuidString
        var registered = false
        var consecutiveFailures = 0
        while true {
            AgentInboxPollIteration.withAgentInboxPollIteration {
                if let agentPID, agentPID > 1, kill(agentPID, 0) != 0, errno == ESRCH {
                    exit(0)
                }
                do {
                    defer { client.close() }
                    let payload = try client.sendV2(
                        method: "agent.message.poll",
                        params: [
                            "surface_id": surfaceId,
                            "poller_key": pollerKey,
                            "register": !registered,
                            "mark_delivered_read": !registered && isStop,
                        ],
                        responseTimeout: 5
                    )
                    registered = true
                    consecutiveFailures = 0
                    if payload["status"] as? String == "superseded" {
                        exit(0)
                    }
                    if (payload["queued"] as? Int ?? 0) > 0, payload["held"] as? Bool != true {
                        let deferred = Self.agentInboxDeferredClaim(
                            surfaceId: surfaceId,
                            via: "claude.wake",
                            pollerKey: pollerKey,
                            client: client
                        )
                        if !deferred.text.isEmpty {
                            FileHandle.standardError.write(Data((deferred.text + "\n").utf8))
                            if let leaseID = deferred.leaseID {
                                _ = Self.agentInboxAcknowledge(
                                    surfaceId: surfaceId,
                                    pollerKey: pollerKey,
                                    leaseID: leaseID,
                                    via: "claude.wake",
                                    client: client
                                )
                            }
                            exit(2)
                        }
                    }
                } catch {
                    // The app may be restarting. Keep trying while Claude lives,
                    // for up to about ten minutes; a restarted app hands the
                    // surface to the first poller that checks in.
                    consecutiveFailures += 1
                    if consecutiveFailures >= Self.agentInboxMaximumPollFailures { exit(0) }
                }
            }
            Thread.sleep(forTimeInterval: Self.agentInboxPollInterval)
        }
    }

    static let agentInboxPollInterval: TimeInterval = 2
    static let agentInboxMaximumPollFailures = 300

    private static func agentInboxDeferredClaim(
        surfaceId: String,
        via: String,
        pollerKey: String,
        client: SocketClient
    ) -> (text: String, leaseID: String?) {
        let payload = try? client.sendV2(
            method: "agent.message.claim",
            params: [
                "surface_id": surfaceId,
                "via": via,
                "mark_delivered_read": false,
                "defer_delivery": true,
                "poller_key": pollerKey,
            ],
            responseTimeout: 3
        )
        return (
            payload?["text"] as? String ?? "",
            payload?["lease_id"] as? String
        )
    }

    @discardableResult
    private static func agentInboxAcknowledge(
        surfaceId: String,
        pollerKey: String,
        leaseID: String,
        via: String,
        client: SocketClient
    ) -> Bool {
        (try? client.sendV2(
            method: "agent.message.ack",
            params: [
                "surface_id": surfaceId,
                "poller_key": pollerKey,
                "lease_id": leaseID,
                "via": via,
            ],
            responseTimeout: 3
        )) != nil
    }

    private static func agentInboxClaim(
        surfaceId: String,
        via: String,
        markDeliveredRead: Bool,
        agentPID: Int?,
        client: SocketClient
    ) -> String {
        var params: [String: Any] = [
            "surface_id": surfaceId,
            "via": via,
            "mark_delivered_read": markDeliveredRead,
        ]
        if let agentPID {
            params["agent_pid"] = agentPID
        }
        guard let payload = try? client.sendV2(
            method: "agent.message.claim",
            params: params,
            responseTimeout: 3
        ) else { return "" }
        return payload["text"] as? String ?? ""
    }

    static func agentInboxPromptSubmitOutput(text: String) -> String {
        guard !text.isEmpty else { return "{}" }
        return agentInboxJSON([
            "hookSpecificOutput": [
                "hookEventName": "UserPromptSubmit",
                "additionalContext": text,
            ],
        ])
    }

    static func agentInboxStopOutput(text: String) -> String {
        guard !text.isEmpty else { return "{}" }
        return agentInboxJSON(["decision": "block", "reason": text])
    }

    private static func agentInboxJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Reads the hook's stdin JSON, bounded to 1 MiB.
    private static func agentInboxHookInput() -> [String: Any] {
        var data = Data()
        let handle = FileHandle.standardInput
        while data.count < 1_048_576 {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
