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
            if Self.agentMessageRequestsHelp(rest) {
                print(Self.agentMessageHelp)
                return true
            }
            try runAgentMessageSend(rest, client: client, jsonOutput: jsonOutput)
            return true
        case "inbox":
            if Self.agentMessageRequestsHelp(rest) {
                print(Self.agentInboxHelp)
                return true
            }
            try runAgentInbox(rest, client: client, jsonOutput: jsonOutput)
            return true
        default:
            return false
        }
    }

    /// `-h`/`--help` before any `--`; words after it are message text.
    static func agentMessageRequestsHelp(_ args: [String]) -> Bool {
        for arg in args {
            if arg == "--" { return false }
            if arg == "-h" || arg == "--help" { return true }
        }
        return false
    }

    /// Parsed `cmux agent message` arguments. Options are read only before
    /// `--`, so the text can contain anything after it.
    struct AgentMessageSendArguments: Equatable {
        var from: String?
        var thread: String?
        var replyTo: String?
        var target: String?
        var body: String
    }

    static func parseAgentMessageSendArguments(_ args: [String]) throws -> AgentMessageSendArguments {
        var from: String?
        var thread: String?
        var replyTo: String?
        var words: [String] = []
        var index = 0
        var pastTerminator = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if pastTerminator {
                words.append(arg)
                continue
            }
            switch arg {
            case "--":
                pastTerminator = true
            case "--json":
                // The global flag; read by the caller.
                continue
            case "--from", "--thread", "--reply-to":
                guard index < args.count else { throw CLIError(message: Self.agentMessageHelp) }
                let value = args[index]
                index += 1
                switch arg {
                case "--from": from = value
                case "--thread": thread = value
                default: replyTo = value
                }
            default:
                words.append(arg)
            }
        }
        // A reply goes to the original sender, so every word is text.
        var target: String?
        if replyTo == nil {
            guard !words.isEmpty else { throw CLIError(message: Self.agentMessageHelp) }
            target = words.removeFirst()
        }
        return AgentMessageSendArguments(
            from: from,
            thread: thread,
            replyTo: replyTo,
            target: target,
            body: words.joined(separator: " ")
        )
    }

    private func runAgentMessageSend(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let parsed = try Self.parseAgentMessageSendArguments(args)
        let (from, thread) = (parsed.from, parsed.thread)
        var params: [String: Any] = [:]
        if let replyTo = parsed.replyTo {
            params["reply_to"] = replyTo
        } else if let target = parsed.target {
            params["target"] = target
        }
        var body = parsed.body
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
        if let limit {
            guard let value = Int(limit) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.agentMessage.invalidLimit", defaultValue: "Invalid --limit value: %@"),
                    limit
                ))
            }
            params["limit"] = value
        }
        let payload = try client.sendV2(method: "agent.message.list", params: params)
        let messages = payload["messages"] as? [[String: Any]] ?? []
        if markRead {
            let ids = messages.compactMap { message -> String? in
                guard message["state"] as? String == "delivered" else { return nil }
                return message["id"] as? String
            }
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
        // Headless `claude -p` and `codex exec` runs share the pane's surface
        // id with the interactive session there; they must not claim its
        // messages.
        let headlessKey = agent == "claude" ? "CMUX_CLAUDE_HEADLESS" : "CMUX_CODEX_HEADLESS"
        let headless = env[headlessKey] == "1"
        guard let surfaceId = env["CMUX_SURFACE_ID"], !surfaceId.isEmpty, env[disabledKey] != "1", !headless else {
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

    /// Claude SessionStart/Stop `asyncRewake` hook. Checks for messages to
    /// this surface every ``agentInboxPollInterval``; when one is waiting it
    /// renders the queued messages to stderr and exits 2, which wakes Claude
    /// with the text as a system reminder. The messages stay queued until the
    /// prompt hook acknowledges them. The prompt box, and any draft in it, is
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
        let isStop = (input["hook_event_name"] as? String) == "Stop"
        let agentPID = env["CMUX_CLAUDE_PID"].flatMap { Int32($0) }
        let pollerKey = UUID().uuidString
        var registered = false
        var consecutiveFailures = 0
        while true {
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
                    let text = Self.agentInboxClaim(
                        surfaceId: surfaceId,
                        via: "claude.wake",
                        markDeliveredRead: false,
                        deferDelivery: true,
                        client: client
                    )
                    if !text.isEmpty {
                        FileHandle.standardError.write(Data((text + "\n").utf8))
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
            Thread.sleep(forTimeInterval: Self.agentInboxPollInterval)
        }
    }

    static let agentInboxPollInterval: TimeInterval = 2
    static let agentInboxMaximumPollFailures = 300

    private static func agentInboxClaim(
        surfaceId: String,
        via: String,
        markDeliveredRead: Bool,
        deferDelivery: Bool = false,
        client: SocketClient
    ) -> String {
        guard let payload = try? client.sendV2(
            method: "agent.message.claim",
            params: [
                "surface_id": surfaceId,
                "via": via,
                "mark_delivered_read": markDeliveredRead,
                "defer_delivery": deferDelivery,
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
