import Foundation

enum AgentSessionProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return String(localized: "agentSession.provider.codex", defaultValue: "Codex")
        case .claude:
            return String(localized: "agentSession.provider.claude", defaultValue: "Claude Code")
        case .opencode:
            return String(localized: "agentSession.provider.opencode", defaultValue: "OpenCode")
        }
    }

    var executableName: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .opencode:
            return "opencode"
        }
    }

    var launchArguments: [String] {
        switch self {
        case .codex:
            return ["app-server", "--listen", "stdio://"]
        case .claude:
            return [
                "-p",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--include-partial-messages",
                "--verbose"
            ]
        case .opencode:
            return ["serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"]
        }
    }

    var transportKind: String {
        switch self {
        case .codex:
            return "stdio-jsonrpc"
        case .claude:
            return "stdio-jsonl"
        case .opencode:
            return "http-loopback"
        }
    }

    var shouldAutoStartSession: Bool {
        switch self {
        case .codex, .opencode:
            return true
        case .claude:
            return false
        }
    }
}
