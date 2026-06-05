import Foundation
import CMUXAgentLaunch

extension TerminalSurface {
    struct CmuxContextEnvironment: Equatable, Sendable {
        let workspaceId: UUID
        let surfaceId: UUID
        let socketPath: String
    }

    static let managedTerminalType = "xterm-256color"
    static let managedTerminalProgram = "ghostty"
    static let managedColorTerm = "truecolor"

    private static let inheritedClaudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]

    static func applyManagedTerminalIdentityEnvironment(
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["TERM"] = managedTerminalType
        protectedKeys.insert("TERM")
        environment["COLORTERM"] = managedColorTerm
        protectedKeys.insert("COLORTERM")
        environment["TERM_PROGRAM"] = managedTerminalProgram
        protectedKeys.insert("TERM_PROGRAM")
    }

    static func applyManagedCmuxContextEnvironment(
        _ context: CmuxContextEnvironment,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        let values = [
            "CMUX_SURFACE_ID": context.surfaceId.uuidString,
            "CMUX_WORKSPACE_ID": context.workspaceId.uuidString,
            "CMUX_PANEL_ID": context.surfaceId.uuidString,
            "CMUX_TAB_ID": context.workspaceId.uuidString,
            "CMUX_SOCKET_PATH": context.socketPath
        ]

        for (key, value) in values {
            environment[key] = value
            protectedKeys.insert(key)
        }
    }

    static func applyManagedGitWatchEnvironment(
        watchGitStatusEnabled: Bool,
        showPullRequestsEnabled: Bool = true,
        to environment: inout [String: String],
        protectedKeys: inout Set<String>
    ) {
        environment["CMUX_NO_GIT_WATCH"] = watchGitStatusEnabled ? "" : "1"
        protectedKeys.insert("CMUX_NO_GIT_WATCH")
        environment["CMUX_NO_PR_WATCH"] = (watchGitStatusEnabled && showPullRequestsEnabled) ? "" : "1"
        protectedKeys.insert("CMUX_NO_PR_WATCH")
    }

    static func mergedStartupEnvironment(
        base: [String: String],
        protectedKeys: Set<String>,
        additionalEnvironment: [String: String],
        initialEnvironmentOverrides: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        applyHermesCodexDefaults: Bool = false
    ) -> [String: String] {
        var merged = base
        for key in inheritedClaudeAuthSelectionEnvironmentKeys where merged[key] != nil || ambientEnvironment[key] != nil {
            merged[key] = ""
        }
        for (key, value) in additionalEnvironment where !key.isEmpty && !value.isEmpty && !protectedKeys.contains(key) {
            merged[key] = value
        }
        for (key, value) in initialEnvironmentOverrides where !protectedKeys.contains(key) {
            merged[key] = value
        }
        if let claudeConfigDir = merged["CLAUDE_CONFIG_DIR"], !claudeConfigDir.isEmpty {
            merged["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(claudeConfigDir)
        }
        if applyHermesCodexDefaults {
            merged = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
                to: merged,
                ambientEnvironment: ambientEnvironment
            )
        }
        return merged
    }
}
