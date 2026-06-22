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
        launchArguments(modelID: nil)
    }

    func launchArguments(modelID: String?) -> [String] {
        let normalizedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = normalizedModel?.isEmpty == false ? normalizedModel : nil
        switch self {
        case .codex:
            let modelArgs = selectedModel.map { ["-c", "model=\(Self.tomlBasicStringLiteral($0))"] } ?? []
            return modelArgs + ["app-server", "--listen", "stdio://"]
        case .claude:
            let modelArgs = selectedModel.map { ["--model", $0] } ?? []
            return modelArgs + [
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

    private static func tomlBasicStringLiteral(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x00...0x1F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
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
