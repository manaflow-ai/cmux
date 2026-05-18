import Foundation
import CMUXAgentLaunch

extension TerminalSurface {
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

    static func mergedStartupEnvironment(
        base: [String: String],
        protectedKeys: Set<String>,
        additionalEnvironment: [String: String],
        initialEnvironmentOverrides: [String: String],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
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
        return merged
    }
}
