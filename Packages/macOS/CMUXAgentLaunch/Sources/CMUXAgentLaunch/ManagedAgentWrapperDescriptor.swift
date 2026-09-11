import Foundation

/// Shared configuration for an agent launched through a cmux-managed wrapper.
struct ManagedAgentWrapperDescriptor: Equatable, Sendable {
    let kind: String
    let executableName: String
    let wrapperShimEnvironmentKey: String
    let customExecutablePathEnvironmentKey: String
    private let sessionIDKind: SessionIDKind

    private enum SessionIDKind: Equatable, Sendable {
        case uuid
        case ampThread
        case hermesSession
    }

    static let claude = Self(
        kind: "claude",
        executableName: "claude",
        wrapperShimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_CLAUDE_PATH",
        sessionIDKind: .uuid
    )

    static let codex = Self(
        kind: "codex",
        executableName: "codex",
        wrapperShimEnvironmentKey: "CMUX_CODEX_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_CODEX_PATH",
        sessionIDKind: .uuid
    )

    static let amp = Self(
        kind: "amp",
        executableName: "amp",
        wrapperShimEnvironmentKey: "CMUX_AMP_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_AMP_PATH",
        sessionIDKind: .ampThread
    )

    static let hermesAgent = Self(
        kind: "hermes-agent",
        executableName: "hermes",
        wrapperShimEnvironmentKey: "CMUX_HERMES_AGENT_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_HERMES_AGENT_PATH",
        sessionIDKind: .hermesSession
    )

    static func registered(kind: String) -> Self? {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case claude.kind: claude
        case codex.kind: codex
        case amp.kind: amp
        case hermesAgent.kind: hermesAgent
        default: nil
        }
    }

    var wrapperShellExecutableToken: String {
        "\"$([ -x \"${\(wrapperShimEnvironmentKey):-}\" ] && printf '%s' \"$\(wrapperShimEnvironmentKey)\" || printf \(executableName))\""
    }

    func portableShellCommand(posixCommand: String) -> String {
        "/bin/sh -c " + Self.posixSingleQuoted(posixCommand)
    }

    func accepts(sessionID: String) -> Bool {
        switch sessionIDKind {
        case .uuid:
            return UUID(uuidString: sessionID) != nil
        case .ampThread:
            guard sessionID.hasPrefix("T-"),
                  (3...256).contains(sessionID.utf8.count) else {
                return false
            }
            return sessionID.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 48...57, 65...90, 95, 97...122:
                    return true
                default:
                    return false
                }
            }
        case .hermesSession:
            return AgentRestoreCLIArgument(rawValue: sessionID) != nil
        }
    }

    /// Single-quotes a value as one POSIX `sh` word.
    private static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
