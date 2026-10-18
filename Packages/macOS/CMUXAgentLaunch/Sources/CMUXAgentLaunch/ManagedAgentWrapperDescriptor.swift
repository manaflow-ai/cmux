import Foundation

/// Shared configuration for an agent launched through a cmux-managed wrapper.
struct ManagedAgentWrapperDescriptor: Equatable, Sendable {
    let kind: String
    let executableName: String
    let acceptedExecutableNames: Set<String>
    let wrapperShimEnvironmentKey: String
    let customExecutablePathEnvironmentKey: String
    let supportsCapturedExecutableFallback: Bool
    private let sessionIDKind: SessionIDKind

    private enum SessionIDKind: Equatable, Sendable {
        case uuid
        case ampThread
        case hermesSession
        case opaque
    }

    static let claude = Self(
        kind: "claude",
        executableName: "claude",
        acceptedExecutableNames: ["claude"],
        wrapperShimEnvironmentKey: "CMUX_CLAUDE_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_CLAUDE_PATH",
        supportsCapturedExecutableFallback: false,
        sessionIDKind: .uuid
    )

    static let codex = Self(
        kind: "codex",
        executableName: "codex",
        acceptedExecutableNames: ["codex"],
        wrapperShimEnvironmentKey: "CMUX_CODEX_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_CODEX_PATH",
        supportsCapturedExecutableFallback: false,
        sessionIDKind: .uuid
    )

    static let amp = Self(
        kind: "amp",
        executableName: "amp",
        acceptedExecutableNames: ["amp"],
        wrapperShimEnvironmentKey: "CMUX_AMP_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_AMP_PATH",
        supportsCapturedExecutableFallback: false,
        sessionIDKind: .ampThread
    )

    static let hermesAgent = Self(
        kind: "hermes-agent",
        executableName: "hermes",
        acceptedExecutableNames: ["hermes"],
        wrapperShimEnvironmentKey: "CMUX_HERMES_AGENT_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_HERMES_AGENT_PATH",
        supportsCapturedExecutableFallback: false,
        sessionIDKind: .hermesSession
    )

    static let antigravity = Self(
        kind: "antigravity",
        executableName: "agy",
        acceptedExecutableNames: ["agy", "antigravity"],
        wrapperShimEnvironmentKey: "CMUX_AGY_WRAPPER_SHIM",
        customExecutablePathEnvironmentKey: "CMUX_CUSTOM_ANTIGRAVITY_PATH",
        supportsCapturedExecutableFallback: true,
        sessionIDKind: .opaque
    )

    static func registered(kind: String) -> Self? {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case claude.kind: claude
        case codex.kind: codex
        case amp.kind: amp
        case hermesAgent.kind: hermesAgent
        case antigravity.kind: antigravity
        default: nil
        }
    }

    var wrapperShellExecutableToken: String {
        wrapperShellExecutableToken(fallbackExecutable: nil)
    }

    func wrapperShellExecutableToken(fallbackExecutable: String?) -> String {
        let fallback = fallbackExecutable.map(Self.posixSingleQuoted) ?? executableName
        let fallbackPrintf = fallbackExecutable == nil ? "printf \(fallback)" : "printf '%s' \(fallback)"
        return "\"$([ -x \"${\(wrapperShimEnvironmentKey):-}\" ] && printf '%s' \"$\(wrapperShimEnvironmentKey)\" || \(fallbackPrintf))\""
    }

    func matchesExecutable(_ value: String) -> Bool {
        acceptedExecutableNames.contains(value)
            || (supportsCapturedExecutableFallback
                && acceptedExecutableNames.contains((value as NSString).lastPathComponent))
    }

    func matchesCapturedExecutable(_ value: String) -> Bool {
        acceptedExecutableNames.contains((value as NSString).lastPathComponent)
    }

    func isBareExecutable(_ value: String) -> Bool {
        acceptedExecutableNames.contains(value)
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
        case .opaque:
            guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else { return false }
            return sessionID.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                    return true
                default:
                    return false
                }
            }
        }
    }

    /// Single-quotes a value as one POSIX `sh` word.
    static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
