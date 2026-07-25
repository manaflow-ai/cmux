import Foundation
import CMUXAgentLaunch

/// An immutable non-decision hook accepted before downstream delivery begins.
nonisolated struct AgentHookDeliveryEvent: Sendable {
    static let maximumPayloadBytes = AgentHookDeliveryPolicy.maximumPayloadBytes
    static let maximumEnvironmentBytes = 64 * 1_024

    private static let allowedHookDataEnvironmentKeys: Set<String> = [
        "PWD",
        "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
        "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
        "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
    ]

    private static let optionalLaunchEnvironmentKeys: Set<String> = [
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
    ]

    let agent: String
    let subcommand: String
    let payload: String
    let socketPath: String
    let relayBacked: Bool
    let environment: [String: String]

    /// Events for one socket and surface retain lifecycle order. The agent PID
    /// is the fallback identity when no surface is available.
    var orderingKey: String {
        Self.orderingKey(agent: agent, socketPath: socketPath, environment: environment)
    }

    var deliveryArguments: [String] {
        switch (agent, subcommand) {
        case ("claude", "feed"):
            return ["hooks", "feed", "--source", "claude"]
        default:
            return ["hooks", agent, subcommand]
        }
    }

    /// High-volume telemetry may use the replaceable ingress reservation, but
    /// tool events that can surface Needs input remain protected with lifecycle
    /// transitions and notifications.
    var isBestEffortTelemetry: Bool {
        if subcommand == "shell-exec" || subcommand == "shell-done" {
            return true
        }
        if agent == "codex", subcommand == "post-tool-use" {
            return true
        }
        guard agent == "claude", subcommand == "pre-tool-use",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = (object["tool_name"] ?? object["toolName"]) as? String else {
            return false
        }
        return toolName != "AskUserQuestion" && toolName != "ExitPlanMode"
    }

    init?(params: [String: Any], deliverySocketPath: String? = nil) {
        let deliveryPolicy = AgentHookDeliveryPolicy()
        guard let agent = params["agent"] as? String,
              let subcommand = params["subcommand"] as? String,
              deliveryPolicy.supportsQueuedDelivery(agent: agent, subcommand: subcommand),
              let payload = params["payload"] as? String,
              payload.utf8.count <= Self.maximumPayloadBytes,
              let socketPath = deliverySocketPath ?? (params["socket_path"] as? String),
              !socketPath.isEmpty,
              socketPath.utf8.count <= 4_096,
              !socketPath.contains("\0"),
              params["relay_backed"] == nil || params["relay_backed"] is Bool,
              let environment = Self.validatedEnvironment(params["environment"], agent: agent) else {
            return nil
        }
        self.agent = agent
        self.subcommand = subcommand
        self.payload = payload
        self.socketPath = socketPath
        self.relayBacked = params["relay_backed"] as? Bool ?? false
        self.environment = environment
    }

    /// Resolves a direct hook's barrier onto the same lane as queued events.
    static func orderingKey(
        params: [String: Any],
        deliverySocketPath: String
    ) -> String? {
        guard let agent = params["agent"] as? String,
              !agent.isEmpty,
              agent.utf8.count <= 128,
              !agent.contains("\0"),
              !deliverySocketPath.isEmpty,
              deliverySocketPath.utf8.count <= 4_096,
              !deliverySocketPath.contains("\0"),
              let environment = validatedEnvironment(params["environment"], agent: agent) else {
            return nil
        }
        return orderingKey(
            agent: agent,
            socketPath: deliverySocketPath,
            environment: environment
        )
    }

    private static func orderingKey(
        agent: String,
        socketPath: String,
        environment: [String: String]
    ) -> String {
        if let surfaceID = environment["CMUX_SURFACE_ID"], !surfaceID.isEmpty {
            return "\(socketPath)\0surface\0\(surfaceID)"
        }
        let pidKey = AgentHookDeliveryPolicy().pidEnvironmentVariable(agentName: agent)
        if let processID = environment[pidKey], !processID.isEmpty {
            return "\(socketPath)\0process\0\(agent)\0\(processID)"
        }
        return "\(socketPath)\0agent\0\(agent)"
    }

    private static func validatedEnvironment(_ rawValue: Any?, agent: String) -> [String: String]? {
        guard let environment = rawValue as? [String: String] else { return nil }
        let replaySafeEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: environment,
            kind: agent
        )
        let pidKey = AgentHookDeliveryPolicy().pidEnvironmentVariable(agentName: agent)
        var candidates: [(key: String, value: String, isOptional: Bool)] = []
        for (key, value) in environment {
            let isAgentPID = key == pidKey
            let isReplaySafe = replaySafeEnvironment[key] == value
            guard allowedHookDataEnvironmentKeys.contains(key) || isAgentPID || isReplaySafe,
                  key.utf8.count <= 128,
                  !key.contains("\0"),
                  !value.contains("\0") else {
                return nil
            }
            let isOptional = optionalLaunchEnvironmentKeys.contains(key) || isReplaySafe
            guard value.utf8.count <= 128 * 1_024 else {
                if isOptional { continue }
                return nil
            }
            candidates.append((key, value, isOptional))
        }
        candidates.sort { lhs, rhs in
            if lhs.isOptional != rhs.isOptional {
                return !lhs.isOptional
            }
            return lhs.key < rhs.key
        }

        var validated: [String: String] = [:]
        var totalBytes = 0
        for candidate in candidates {
            let entryBytes = candidate.key.utf8.count + candidate.value.utf8.count + 2
            guard totalBytes + entryBytes <= maximumEnvironmentBytes else {
                if candidate.isOptional { continue }
                return nil
            }
            validated[candidate.key] = candidate.value
            totalBytes += entryBytes
        }
        return validated
    }
}
