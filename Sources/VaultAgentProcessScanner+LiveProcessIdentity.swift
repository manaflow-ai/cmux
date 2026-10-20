import Foundation

extension RestorableAgentSessionIndex {
    /// Whether a live scoped process's executable is credibly the agent the hook
    /// record captured: exact basename match, the launch-time executable recorded
    /// in the process's own cmux launch environment, or a known agent entrypoint
    /// shape in argv (versioned claude installs, node-launched codex, etc.).
    static func liveProcessExecutableMatchesRecordedAgent(
        kind: RestorableAgentKind,
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }
        if CachedAgentProcessIdentityValidator.liveProcessMatchesLaunchExecutableEnvironment(
            kind: kind,
            executableCandidates: [liveExecutable],
            environment: environment
        ) {
            return true
        }

        return CachedAgentProcessIdentityValidator.liveClaudeProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
            || CachedAgentProcessIdentityValidator.liveCodexProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
    }
}
