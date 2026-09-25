import CmuxAgentJournal
import CryptoKit
import Foundation

extension CMUXCLI {
    /// Handles the provider-neutral, exact-session objective hook.
    func runAgentGoalStateCommand(
        commandArgs rawArgs: [String],
        client: SocketClient,
        processEnv: [String: String],
        jsonOutput: Bool
    ) throws {
        var args = rawArgs
        let localJSONOutput = jsonOutput || args.contains("--json")
        args.removeAll(where: { $0 == "--json" })
        guard args.first?.lowercased() == "goal-state" else {
            throw CLIError(message: agentGoalStateUsage())
        }
        args.removeFirst()
        if args.first == "--help" || args.first == "-h" {
            print(agentGoalStateUsage())
            return
        }
        let (agentRaw, rem0) = parseOption(args, name: "--agent")
        let (sessionRaw, rem1) = parseOption(rem0, name: "--session")
        let (generationRaw, rem2) = parseOption(rem1, name: "--generation")
        let (previousGenerationRaw, rem3) = parseOption(rem2, name: "--previous-generation")
        let (provenanceRaw, rem4) = parseOption(rem3, name: "--provenance")
        let (workspaceRaw, rem5) = parseOption(rem4, name: "--workspace")
        let (surfaceRaw, rem6) = parseOption(rem5, name: "--surface")
        let (updatedAtRaw, rem7) = parseOption(rem6, name: "--updated-at-ms")
        let (eventIDRaw, rem8) = parseOption(rem7, name: "--event-id")
        let remaining = rem8
        guard let stateRaw = remaining.first,
              remaining.dropFirst().isEmpty else {
            throw CLIError(message: agentGoalStateUsage())
        }
        guard let agentInput = normalizedHookValue(agentRaw) else {
            throw CLIError(message: String(localized: "cli.agent.goalState.error.agentRequired", defaultValue: "--agent is required."))
        }
        let normalizedAgent = agentInput.lowercased() == "claude-code" || agentInput.lowercased() == "claude_code"
            ? "claude" : agentInput.lowercased()
        let resolvedAgent: String
        if normalizedAgent == "claude" {
            resolvedAgent = "claude"
        } else if let definition = Self.agentDef(named: normalizedAgent) {
            resolvedAgent = definition.name
        } else {
            throw CLIError(message: String(localized: "cli.agent.goalState.error.unknownAgent", defaultValue: "Unknown agent."))
        }
        let state: AgentGoalLifecycleState
        if resolvedAgent == "codex" {
            state = CodexGoalLifecycleAdapter().state(for: stateRaw)
        } else if let parsed = AgentGoalLifecycleState(rawValue: stateRaw.lowercased()) {
            state = parsed
        } else {
            throw CLIError(message: String(
                format: String(localized: "cli.agent.goalState.error.invalidState", defaultValue: "Invalid goal state '%@'."),
                stateRaw
            ))
        }
        guard let sessionID = normalizedHookValue(sessionRaw),
              let generation = normalizedHookValue(generationRaw) else {
            throw CLIError(message: String(localized: "cli.agent.goalState.error.identityRequired", defaultValue: "--session and --generation are required."))
        }
        let provenance = normalizedHookValue(provenanceRaw) ?? "generic_hook"
        let workspaceID = normalizedHookValue(workspaceRaw) ?? normalizedHookValue(processEnv["CMUX_WORKSPACE_ID"])
        let surfaceID = normalizedHookValue(surfaceRaw) ?? normalizedHookValue(processEnv["CMUX_SURFACE_ID"])
        guard let workspaceID, let surfaceID else {
            throw CLIError(message: String(localized: "cli.agent.goalState.error.targetRequired", defaultValue: "A workspace and surface identity are required; pass --workspace and --surface or use the cmux hook environment."))
        }
        let updatedAtMs: Int64
        if let updatedAtRaw {
            guard let parsed = Int64(updatedAtRaw), parsed >= 0 else {
                throw CLIError(message: String(localized: "cli.agent.goalState.error.invalidTimestamp", defaultValue: "--updated-at-ms must be a non-negative integer."))
            }
            updatedAtMs = parsed
        } else {
            updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        }
        let lifecycle = AgentGoalLifecycle(
            state: state,
            generation: generation,
            updatedAtMs: updatedAtMs,
            provenance: provenance,
            previousGeneration: normalizedHookValue(previousGenerationRaw)
        )
        if let problem = lifecycle.validationProblem() {
            throw CLIError(message: String(
                format: String(localized: "cli.agent.goalState.error.invalidValue", defaultValue: "Invalid goal lifecycle value: %@"),
                problem
            ))
        }

        let eventID = normalizedHookValue(eventIDRaw) ?? goalLifecycleEventID(
            agent: resolvedAgent,
            sessionID: sessionID,
            lifecycle: lifecycle
        )
        let source = resolvedAgent
        let draft = AgentJournalEventDraft(
            eventId: eventID,
            kind: .goalStateChanged,
            occurredAtMs: lifecycle.updatedAtMs,
            source: source,
            agentKey: source,
            sessionId: sessionID,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            nativeEvent: "goal-state",
            goalLifecycle: lifecycle
        )
        if let problem = draft.validationProblem() {
            throw CLIError(message: String(
                format: String(localized: "cli.agent.goalState.error.invalidValue", defaultValue: "Invalid goal lifecycle value: %@"),
                problem
            ))
        }
        let data = try JSONEncoder().encode(draft)
        let socketResponse = try client.send(
            command: "agent_journal_append \(String(decoding: data, as: UTF8.self))",
            responseTimeout: 2,
            deadline: Date.now.addingTimeInterval(3)
        )
        guard socketResponse.hasPrefix("OK") else {
            throw CLIError(message: String(localized: "cli.agent.goalState.error.rejected", defaultValue: "Goal lifecycle update was rejected."))
        }
        let response: [String: Any] = [
            "goal_lifecycle": lifecycle.state.rawValue,
            "goal_updated_at_unix": Double(lifecycle.updatedAtMs) / 1_000,
            "goal_provenance": lifecycle.provenance,
            "result": socketResponse.contains("replayed") ? "replayed" : "updated",
            "event_emitted": true,
        ]
        if localJSONOutput {
            print(jsonString(response))
        } else if socketResponse.contains("replayed") {
            print(String(localized: "cli.agent.goalState.output.replayed", defaultValue: "OK replayed"))
        } else {
            print(String(localized: "cli.agent.goalState.output.updated", defaultValue: "OK updated"))
        }
    }

    private func goalLifecycleEventID(
        agent: String,
        sessionID: String,
        lifecycle: AgentGoalLifecycle
    ) -> String {
        let input = [agent, sessionID, lifecycle.generation, lifecycle.previousGeneration ?? "",
                     lifecycle.state.rawValue, String(lifecycle.updatedAtMs), lifecycle.provenance].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func agentGoalStateUsage() -> String {
        String(localized: "cli.agent.goalState.usage", defaultValue: "Usage: cmux agent goal-state <state> --agent <name> --session <id> --generation <id> [--previous-generation <id>] [--provenance <slug>] [--workspace <uuid>] [--surface <uuid>] [--updated-at-ms <n>] [--event-id <id>] [--json]")
            + "\n\n"
            + String(localized: "cli.agent.goalState.description", defaultValue: "Record authoritative objective state for one exact agent session. The generation fences late updates from an earlier objective.")
    }
}
