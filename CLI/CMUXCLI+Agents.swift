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
          --limit <n>           Limit rows (default: 100; with --all: unlimited)

        Tree options:
          --relation <kind>     Filter edges to spawned, forked, or resumed
          --depth <n>           Limit rendered tree depth (default: 64; maximum: 4096)
          --max-nodes <n>       Cap graph nodes (default: 10000; maximum: 20000)

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

    func agentsWriteStoreWarnings(_ warnings: [AgentHookSessionStoreLoadWarning]) {
        for warning in warnings {
            let format = switch warning.fallback {
            case .legacy:
                String(
                    localized: "cli.agents.warning.authoritativeSnapshotDecodeFailed.legacy",
                    defaultValue: "Warning [%@]: saved %@ agent state at %@ is damaged; using the last complete fallback, so newer sessions may be missing."
                )
            case .registry:
                String(
                    localized: "cli.agents.warning.legacySourceImportFailed.registry",
                    defaultValue: "Warning [%@]: saved %@ agent state at %@ could not be imported; using the last complete registry snapshot, so newer sessions may be missing."
                )
            }
            cliWriteStderr(String(
                format: format,
                warning.code.rawValue,
                warning.provider,
                warning.path
            ) + "\n")
        }
    }

    func agentsStoreLoadCLIError(
        _ failure: AgentHookSessionStoreLoadFailure,
        context: AgentsValueOptionContext,
        jsonOutput: Bool
    ) -> CLIError {
        let isTreeContext = switch context {
        case .tree: true
        case .list: false
        }
        let isGraphBudget = isTreeContext
            && (failure.scope == .legacyGraphNodes || failure.scope == .registryGraphNodes)
        let externalCode = isGraphBudget
            ? "agent_graph_node_budget_exceeded"
            : failure.code.rawValue
        let failureHasLegacyScope = switch failure.scope {
        case .legacyFile?, .legacySessions?, .legacyGraphNodes?, .legacyRecord?: true
        default: false
        }
        let isLegacyStorageLimit = !isGraphBudget && failureHasLegacyScope
        let canonicalPath = isLegacyStorageLimit
            ? (failure.canonicalPath ?? URL(fileURLWithPath: failure.path).deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
                .path)
            : nil
        let storageGuidance: String? = if failure.code == .storageLimitExceeded {
            if isGraphBudget {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.graph",
                        defaultValue: "Narrow the selection with --agent %@ or raise --max-nodes, up to %lld."
                    ),
                    failure.provider,
                    Self.agentsTreeHardMaximumNodes
                )
            } else if let canonicalPath {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.legacy",
                        defaultValue: "Move %@ aside without deleting it, then rerun so cmux can rebuild it from %@. If that database has no %@ rows, keep the moved file and restore it before proceeding."
                    ),
                    failure.path,
                    canonicalPath,
                    failure.provider
                )
            } else {
                String(
                    format: String(
                        localized: "cli.agents.error.storageLimitGuidance.canonical",
                        defaultValue: "Retry with --agent %@ to narrow the selection; inspect the canonical store at %@ before changing it."
                    ),
                    failure.provider,
                    failure.path
                )
            }
        } else {
            nil
        }
        let message: String
        if failure.code == .storageLimitExceeded,
           let scope = failure.scope,
           let storageGuidance {
            if let observedBytes = failure.observedBytes,
               let maximumBytes = failure.maximumBytes,
               let sessionID = failure.sessionID {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceeded.session",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit for session %@ (%lld bytes observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    sessionID,
                    observedBytes,
                    maximumBytes,
                    storageGuidance
                )
            } else if let observedBytes = failure.observedBytes,
                      let maximumBytes = failure.maximumBytes {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceeded",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit (%lld bytes observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    observedBytes,
                    maximumBytes,
                    storageGuidance
                )
            } else if let observedCount = failure.observedCount,
                      let maximumCount = failure.maximumCount,
                      let sessionID = failure.sessionID {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceededCount.session",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit for session %@ (%lld entries observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    sessionID,
                    observedCount,
                    maximumCount,
                    storageGuidance
                )
            } else if let observedCount = failure.observedCount,
                      let maximumCount = failure.maximumCount {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storageLimitExceededCount",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ exceeds the %@ inspection limit (%lld entries observed, %lld maximum); %@"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path,
                    scope.rawValue,
                    observedCount,
                    maximumCount,
                    storageGuidance
                )
            } else {
                message = String(
                    format: String(
                        localized: "cli.agents.error.storeLoadFailed",
                        defaultValue: "agents: [%@] saved %@ agent state at %@ could not be read and no complete fallback is available"
                    ),
                    externalCode,
                    failure.provider,
                    failure.path
                )
            }
        } else {
            message = String(
                format: String(
                    localized: "cli.agents.error.storeLoadFailed",
                    defaultValue: "agents: [%@] saved %@ agent state at %@ could not be read and no complete fallback is available"
                ),
                externalCode,
                failure.provider,
                failure.path
            )
        }

        if jsonOutput {
            var error: [String: Any] = [
                "code": externalCode,
                "provider": failure.provider,
                "path": failure.path,
                "scope": failure.scope?.rawValue ?? NSNull(),
                "session_id": failure.sessionID ?? NSNull(),
                "observed_bytes": failure.observedBytes ?? NSNull(),
                "maximum_bytes": failure.maximumBytes ?? NSNull(),
                "observed_count": failure.observedCount ?? NSNull(),
                "maximum_count": failure.maximumCount ?? NSNull(),
                "message": message,
            ]
            if let storageGuidance {
                error["guidance"] = storageGuidance
                error["recovery_action"] = if isGraphBudget {
                    "narrow_graph_selection"
                } else if isLegacyStorageLimit {
                    "move_legacy_file_aside"
                } else {
                    "narrow_agent_selection"
                }
            }
            if let canonicalPath { error["canonical_path"] = canonicalPath }
            if isGraphBudget {
                error["limit"] = failure.maximumCount ?? NSNull()
                error["observed_at_least"] = failure.observedCount ?? NSNull()
            }
            var payload: [String: Any] = [
                "schema_version": 2,
                "error": error,
            ]
            switch context {
            case .list:
                payload["sessions"] = []
            case .tree:
                payload["nodes"] = []
                payload["edges"] = []
            }
            cliWriteStdout(jsonString(payload) + "\n")
        }
        return CLIError(message: message, v2Code: externalCode)
    }

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
