import Foundation
import CMUXAgentLaunch

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
        environment: [String: String],
        launchExecutableMatcher: AgentLaunchExecutableMatcher
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }
        if launchExecutableMatcher.matches(
            kind: kind.rawValue,
            executableCandidates: [liveExecutable],
            recordedKind: environment["CMUX_AGENT_LAUNCH_KIND"],
            recordedExecutable: environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]
        ) {
            return true
        }

        return CachedAgentProcessIdentityValidator.liveClaudeProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
            || CachedAgentProcessIdentityValidator.liveCodexProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
    }
}
