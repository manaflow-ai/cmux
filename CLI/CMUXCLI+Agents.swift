import CmuxFoundation
import Foundation

extension CMUXCLI {
    enum AgentsValueOptionContext {
        case list
        case tree
    }

    func runAgentsCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        terminalObservations: [CmuxAgentTerminalObservation] = []
    ) throws {
        let subcommand = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subcommand == "tree" {
            try runAgentsTreeCommand(
                commandArgs: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput,
                processEnv: processEnv,
                fileManager: fileManager,
                terminalObservations: terminalObservations
            )
            return
        }
        try runSessionsCommand(
            commandArgs: commandArgs,
            jsonOutput: jsonOutput,
            processEnv: processEnv,
            fileManager: fileManager,
            terminalObservations: terminalObservations
        )
    }

    func agentsUsage() -> String {
        String(localized: "cli.sessions.usage", defaultValue: """
        Usage: cmux agents list [options]
               cmux agents tree [options]
               cmux agents [options]

        Print saved session lifecycle plus cached live terminal state.
        With a cmux socket, this queries runtime identity and cached observations once.
        Without a socket, it reads saved hook state from ~/.cmuxterm.
        Inside cmux, default output is scoped to that running app process.
        Pass --all to inspect cross-runtime history.

        `agents tree` renders process-spawn and conversation-fork relationships.
        Add --json for a flat, versioned nodes-and-edges graph.

        Options:
          --agent <name>        Filter to one agent, for example codex or claude
          --session <id>        Filter to one agent session id
          --workspace <id>      Filter to one saved workspace id
          --surface <id>        Filter to one saved surface id
          --state-dir <path>    Override hook state directory
          --state <state>       Filter by effective state
          --activity <state>    Filter by busy, idle, or unknown activity
          --work-kind <kind>    Filter by an active workload kind
          --all                 Print all matches
          --json                Print structured JSON

        List options:
          --cwd <text>          Filter by saved cwd or launch working directory
          --codex-home <path>   Override the default Codex home used for transcript checks
          --limit <n>           Limit text output (default: 100)

        Tree options:
          --relation <kind>     Filter edges to spawned, forked, or resumed
          --depth <n>           Limit rendered tree depth (default: 64)

        Codex rows include whether the saved id exists in CODEX_HOME/session_index.jsonl
        and whether a matching transcript file exists under CODEX_HOME/sessions or
        CODEX_HOME/archived_sessions.

        Compatibility aliases:
          cmux sessions [list|tree] [options]
          cmux sessions debug [options]
          cmux session-debug [options]
        """)
    }

    func sessionsUsage() -> String { agentsUsage() }

    func sessionsListEncodableJSONObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return object
    }

    func decodeAgentTerminalObservations(
        _ response: [String: Any],
        expectedRuntimeID: String?
    ) throws -> [CmuxAgentTerminalObservation] {
        guard let runtimeID = response["runtime_id"] as? String,
              expectedRuntimeID == nil || runtimeID == expectedRuntimeID else {
            throw CLIError(message: String(
                localized: "cli.agents.error.runtimeMismatch",
                defaultValue: "agents: live observation runtime does not match the connected cmux instance"
            ))
        }
        guard let observations = response["observations"] as? [Any],
              JSONSerialization.isValidJSONObject(observations) else { return [] }
        let data = try JSONSerialization.data(withJSONObject: observations)
        return try JSONDecoder().decode([CmuxAgentTerminalObservation].self, from: data)
    }

    func agentSessionProviderID(
        for requestedAgent: String,
        terminalObservations: [CmuxAgentTerminalObservation]
    ) -> String? {
        let normalized = agentsNormalizedAgentID(requestedAgent)
        if normalized == "claude" || normalized == "claude-code" {
            return "claude"
        }
        if let definition = Self.agentDef(named: normalized) {
            return definition.name
        }
        let observedProviders = Set(terminalObservations.compactMap { observation -> String? in
            guard agentTerminalObservation(observation, matchesAnyAgentID: [normalized]) else {
                return nil
            }
            return agentsNormalizedAgentID(observation.sessionProviderID)
        })
        guard observedProviders.count == 1 else { return nil }
        return observedProviders.first
    }

    func agentTerminalObservation(
        _ observation: CmuxAgentTerminalObservation,
        matchesAnyAgentID agentIDs: Set<String>
    ) -> Bool {
        let normalizedIDs = Set(agentIDs.map(agentsNormalizedAgentID))
        let provider = agentsNormalizedAgentID(observation.sessionProviderID)
        let family = agentsNormalizedAgentID(observation.familyID)
        return normalizedIDs.contains(provider) || normalizedIDs.contains(family)
    }

    func agentsNormalizedAgentID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    func parseAgentsValueOption(
        _ arguments: [String],
        name: String,
        context: AgentsValueOptionContext
    ) throws -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false

        for (index, argument) in arguments.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "--" {
                pastTerminator = true
                remaining.append(argument)
                continue
            }
            if !pastTerminator, argument.hasPrefix("\(name)=") {
                let candidate = String(argument.dropFirst(name.count + 1))
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                value = candidate
                continue
            }
            if !pastTerminator, argument == name {
                guard index + 1 < arguments.count else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                let candidate = arguments[index + 1]
                guard !candidate.hasPrefix("-"),
                      !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: agentsOptionRequiresValueMessage(name: name, context: context))
                }
                value = candidate
                skipNext = true
                continue
            }
            remaining.append(argument)
        }

        return (value, remaining)
    }

    private func agentsOptionRequiresValueMessage(
        name: String,
        context: AgentsValueOptionContext
    ) -> String {
        let agentMessage = switch context {
        case .list:
            String(
                localized: "cli.sessions.error.agentRequiresValue",
                defaultValue: "sessions list: --agent requires a value"
            )
        case .tree:
            String(
                localized: "cli.agents.tree.error.agentRequiresValue",
                defaultValue: "agents tree: --agent requires a value"
            )
        }
        return agentMessage.replacingOccurrences(of: "--agent", with: name)
    }
}
