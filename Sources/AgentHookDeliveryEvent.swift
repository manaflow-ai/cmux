import Foundation
import CMUXAgentLaunch

/// An immutable non-decision hook accepted before downstream delivery begins.
nonisolated struct AgentHookDeliveryEvent: Sendable {
    static let maximumPayloadBytes = 8 * 1024 * 1024
    static let maximumEnvironmentBytes = 256 * 1024

    private static let allowedHookDataEnvironmentKeys: Set<String> = [
        "PWD",
        "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
        "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_CLAUDE_PID",
        "CMUX_CODEX_PID", "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
        "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
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
        if let surfaceID = environment["CMUX_SURFACE_ID"], !surfaceID.isEmpty {
            return "\(socketPath)\0surface\0\(surfaceID)"
        }
        let pidKey = agent == "claude" ? "CMUX_CLAUDE_PID" : "CMUX_CODEX_PID"
        if let processID = environment[pidKey], !processID.isEmpty {
            return "\(socketPath)\0process\0\(agent)\0\(processID)"
        }
        return "\(socketPath)\0agent\0\(agent)"
    }

    var deliveryArguments: [String] {
        switch (agent, subcommand) {
        case ("claude", "feed"):
            return ["hooks", "feed", "--source", "claude"]
        default:
            return ["hooks", agent, subcommand]
        }
    }

    init?(params: [String: Any], deliverySocketPath: String? = nil) {
        guard let agent = params["agent"] as? String,
              let subcommand = params["subcommand"] as? String,
              Self.supports(agent: agent, subcommand: subcommand),
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

    private static func supports(agent: String, subcommand: String) -> Bool {
        switch (agent, subcommand) {
        case ("claude", "session-start"), ("claude", "stop"),
             ("claude", "session-end"), ("claude", "notification"),
             ("claude", "prompt-submit"), ("claude", "pre-tool-use"),
             ("claude", "push-notification"), ("claude", "feed"),
             ("codex", "session-start"), ("codex", "prompt-submit"),
             ("codex", "stop"), ("codex", "post-tool-use"):
            return true
        default:
            return false
        }
    }

    private static func validatedEnvironment(_ rawValue: Any?, agent: String) -> [String: String]? {
        guard let environment = rawValue as? [String: String] else { return nil }
        let replaySafeEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: environment,
            kind: agent
        )
        var totalBytes = 0
        for (key, value) in environment {
            guard allowedHookDataEnvironmentKeys.contains(key) || replaySafeEnvironment[key] == value,
                  key.utf8.count <= 128,
                  value.utf8.count <= 128 * 1024,
                  !key.contains("\0"),
                  !value.contains("\0") else {
                return nil
            }
            totalBytes += key.utf8.count + value.utf8.count + 2
            guard totalBytes <= maximumEnvironmentBytes else { return nil }
        }
        return environment
    }
}
