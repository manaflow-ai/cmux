import Foundation

/// `cmux agent message`, `cmux agent inbox`, and the agent hooks that deliver
/// messages through the agent's own input path instead of its terminal.
extension CMUXCLI {
    static var agentMessageHelp: String {
        String(localized: "cli.help.agentMessage", defaultValue: """
        Usage: cmux agent message <target> [--from <name>] [--thread <id>] [--json] [--] <text|->
               cmux agent message --reply-to <message-id> [--from <name>] [--json] [--] <text|->

        Send a message to the agent running in another workspace or surface. cmux
        delivers it through that agent's hooks, never by typing into its terminal,
        so it cannot land in a half-typed prompt. An idle Claude Code session wakes
        up to read it; a busy one reads it at its next step.

        <target> is a workspace or surface id or ref (workspace:2, surface:5), or a
        workspace title (exact, then a unique prefix). Use - to read the text from
        stdin. --from defaults to the sending workspace's title.

        Examples:
          cmux agent message cmux-remote-status "The relay fix is on main, rebase when free."
          cmux agent message --reply-to 3f2a... "Done, PR is #123."
        """)
    }

    static var agentInboxHelp: String {
        String(localized: "cli.help.agentInbox", defaultValue: """
        Usage: cmux agent inbox [--surface <target>] [--state queued|delivered|read] [--limit <n>] [--mark-read] [--json]

        List agent messages, newest first. Without --surface, lists messages for
        every surface. --mark-read marks the listed messages read.
        """)
    }

    /// Handles `cmux agent message|inbox`. Returns false for other `agent`
    /// subcommands, which stay aliases of `cmux vm agent`.
    func runAgentMessageCommandIfMatched(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws -> Bool {
        guard let first = commandArgs.first?.lowercased() else { return false }
        let rest = Array(commandArgs.dropFirst())
        switch first {
        case "message", "msg":
            if rest.contains("--help") || rest.contains("-h") {
                print(Self.agentMessageHelp)
                return true
            }
            try runAgentMessageSend(rest, client: client, jsonOutput: jsonOutput)
            return true
        case "inbox":
            if rest.contains("--help") || rest.contains("-h") {
                print(Self.agentInboxHelp)
                return true
            }
            try runAgentInbox(rest, client: client, jsonOutput: jsonOutput)
            return true
        default:
            return false
        }
    }

    private func runAgentMessageSend(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (from, rem0) = parseOption(args, name: "--from")
        let (thread, rem1) = parseOption(rem0, name: "--thread")
        let (replyTo, rem2) = parseOption(rem1, name: "--reply-to")
        var positional = rem2.filter { $0 != "--json" }
        if positional.first == "--" { positional.removeFirst() }

        var params: [String: Any] = [:]
        if let replyTo {
            params["reply_to"] = replyTo
        } else {
            guard !positional.isEmpty else { throw CLIError(message: Self.agentMessageHelp) }
            params["target"] = positional.removeFirst()
            if positional.first == "--" { positional.removeFirst() }
        }
        var body = positional.joined(separator: " ")
        if body == "-" {
            body = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: Self.agentMessageHelp)
        }
        params["body"] = body
        if let from { params["from"] = from }
        if let thread { params["thread_id"] = thread }
        let env = ProcessInfo.processInfo.environment
        if let surface = env["CMUX_SURFACE_ID"], !surface.isEmpty { params["sender_surface_id"] = surface }
        if let workspace = env["CMUX_WORKSPACE_ID"], !workspace.isEmpty { params["sender_workspace_id"] = workspace }

        let payload = try client.sendV2(method: "agent.message.send", params: params)
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let id = payload["id"] as? String ?? "?"
        let title = payload["recipient_workspace_title"] as? String ?? ""
        let surfaceRef = payload["recipient_surface_ref"] as? String ?? ""
        print(String(
            format: String(
                localized: "cli.agentMessage.queued",
                defaultValue: "Queued message %@ for %@ (%@)."
            ),
            id, title, surfaceRef
        ))
        if payload["recipient_has_agent"] as? Bool == false {
            FileHandle.standardError.write(Data((String(
                localized: "cli.agentMessage.noAgent",
                defaultValue: "No agent activity seen on that surface yet. The message waits until an agent there picks it up."
            ) + "\n").utf8))
        }
    }

    private func runAgentInbox(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (surface, rem0) = parseOption(args, name: "--surface")
        let (state, rem1) = parseOption(rem0, name: "--state")
        let (limit, rem2) = parseOption(rem1, name: "--limit")
        let markRead = rem2.contains("--mark-read")
        var params: [String: Any] = [:]
        if let surface { params["surface"] = surface }
        if let state { params["state"] = state }
        if let limit, let value = Int(limit) { params["limit"] = value }
        let payload = try client.sendV2(method: "agent.message.list", params: params)
        let messages = payload["messages"] as? [[String: Any]] ?? []
        if markRead {
            let ids = messages.compactMap { $0["id"] as? String }
            if !ids.isEmpty {
                _ = try client.sendV2(method: "agent.message.mark_read", params: ["ids": ids])
            }
        }
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        for message in messages {
            print(Self.agentInboxLine(message))
        }
    }

    /// One line per message: state, short id, sender, first line of the body.
    static func agentInboxLine(_ message: [String: Any]) -> String {
        let state = (message["state"] as? String ?? "?").padding(toLength: 9, withPad: " ", startingAt: 0)
        let id = String((message["id"] as? String ?? "?").prefix(8))
        let sender = message["sender_name"] as? String ?? "?"
        let firstLine = (message["body"] as? String ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let clipped = firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
        return "\(state) \(id)  \(sender): \(clipped)"
    }

    // MARK: - Hooks

    /// Handles `hooks <claude|codex> inbox-*`. Returns false for any other
    /// hook subcommand. Every path fails open: a missing surface, a disabled
    /// integration or a socket error prints the agent's no-op answer.
    func runAgentInboxHookIfMatched(
        agent: String,
        commandArgs: [String],
        client: SocketClient
    ) throws -> Bool {
        guard let subcommand = commandArgs.first?.lowercased(),
              subcommand.hasPrefix("inbox-") else { return false }
        let env = ProcessInfo.processInfo.environment
        let input = Self.agentInboxHookInput()
        let disabledKey = agent == "claude" ? "CMUX_CLAUDE_HOOKS_DISABLED" : "CMUX_CODEX_HOOKS_DISABLED"
        guard let surfaceId = env["CMUX_SURFACE_ID"], !surfaceId.isEmpty, env[disabledKey] != "1" else {
            if subcommand != "inbox-wait" { print("{}") }
            return true
        }
        switch (agent, subcommand) {
        case ("claude", "inbox-wait"):
            runClaudeInboxWait(surfaceId: surfaceId, input: input, client: client, env: env)
        case (_, "inbox-drain"):
            // UserPromptSubmit: attach pending messages to the prompt the
            // human just sent.
            let text = Self.agentInboxClaim(
                surfaceId: surfaceId,
                via: "\(agent).prompt-submit",
                markDeliveredRead: false,
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
                client: client
            )
            print(Self.agentInboxStopOutput(text: text))
        default:
            print("{}")
        }
        fflush(stdout)
        return true
    }

    /// Claude SessionStart/Stop `asyncRewake` hook. Waits in the background
    /// for a message to this surface; on delivery it writes the message to
    /// stderr and exits 2, which wakes Claude with the text as a system
    /// reminder. The prompt box, and any draft in it, is never touched.
    private func runClaudeInboxWait(
        surfaceId: String,
        input: [String: Any],
        client: SocketClient,
        env: [String: String]
    ) -> Never {
        let sessionId = (input["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? surfaceId
        let isStop = (input["hook_event_name"] as? String) == "Stop"
        let agentPID = env["CMUX_CLAUDE_PID"].flatMap { Int32($0) }
        var markDeliveredRead = isStop
        var consecutiveFailures = 0
        while true {
            if let agentPID, agentPID > 1, kill(agentPID, 0) != 0, errno == ESRCH {
                exit(0)
            }
            do {
                let payload = try client.sendV2(
                    method: "agent.message.wait",
                    params: [
                        "surface_id": surfaceId,
                        "waiter_key": "claude:\(sessionId)",
                        "via": "claude.wake",
                        "timeout_ms": Self.agentInboxWaitMilliseconds,
                        "mark_delivered_read": markDeliveredRead,
                    ],
                    responseTimeout: TimeInterval(Self.agentInboxWaitMilliseconds / 1_000 + 30)
                )
                markDeliveredRead = false
                consecutiveFailures = 0
                switch payload["status"] as? String {
                case "delivered":
                    let text = payload["text"] as? String ?? ""
                    guard !text.isEmpty else { continue }
                    FileHandle.standardError.write(Data((text + "\n").utf8))
                    exit(2)
                case "superseded":
                    exit(0)
                default:
                    continue
                }
            } catch {
                // The app may be restarting; give up after about a minute.
                consecutiveFailures += 1
                if consecutiveFailures >= 12 { exit(0) }
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    static let agentInboxWaitMilliseconds = 600_000

    private static func agentInboxClaim(
        surfaceId: String,
        via: String,
        markDeliveredRead: Bool,
        client: SocketClient
    ) -> String {
        guard let payload = try? client.sendV2(
            method: "agent.message.claim",
            params: [
                "surface_id": surfaceId,
                "via": via,
                "mark_delivered_read": markDeliveredRead,
            ],
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
