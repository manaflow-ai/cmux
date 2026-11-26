import CMUXAgentLaunch
import Foundation

/// Why waking a hibernated agent would not relaunch it the way it was started.
enum AgentHibernationLaunchFidelityProblem: String, Sendable, Equatable {
    /// Claude has no usable captured argv, so a wake would replay a bare
    /// `claude --resume` and skip whatever started it (`sr claude proxy`, a
    /// wrapper, a custom binary, launch flags).
    case missingClaudeLaunchCapture
    /// The capture names a declared `agents.launchers` entry that no longer
    /// resolves, so a wake would drop the launcher prefix.
    case externalLauncherUnavailable
}

extension SessionRestorableAgentSnapshot {
    /// The reason a hibernation wake could not reproduce this agent's launch,
    /// or `nil` when it can. Hibernation refuses such panes: tearing down an
    /// agent is only safe when the wake brings back the same agent.
    var hibernationLaunchFidelityProblem: AgentHibernationLaunchFidelityProblem? {
        if kind == .claude, launchCommand?.arguments.isEmpty ?? true,
           !SubrouterClaudeResumeRouting().provesRoutedLaunch(
               launcher: launchCommand?.launcher,
               environment: launchCommand?.environment
           ) {
            // A proven Subrouter launch wakes through its launcher even without
            // a captured argv.
            return .missingClaudeLaunchCapture
        }
        if let launcherID = launchCommand?.externalLauncher,
           !launcherID.isEmpty,
           AgentResumeCommandBuilder.externalLauncher(
               kind: kind,
               sessionId: sessionId,
               launchCommand: launchCommand,
               // Match `cmux restore`, which searches from the launch directory.
               workingDirectory: launchCommand?.workingDirectory ?? workingDirectory
           ) == nil,
           !AgentResumeArgv().resumeRoutesThroughOwnedLauncher(
               launcher: launchCommand?.launcher,
               sessionId: sessionId,
               executablePath: launchCommand?.executablePath,
               arguments: launchCommand?.arguments ?? [],
               environment: launchCommand?.environment
           ) {
            return .externalLauncherUnavailable
        }
        return nil
    }
}
