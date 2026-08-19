import Foundation
import CMUXAgentLaunch

extension SessionRestorableAgentSnapshot {
    /// Builds the durable hook binding that can relaunch this agent session.
    ///
    /// The snapshot is the app's authoritative, structured identity for an agent. Keeping the
    /// binding derivation here gives session-save backfill and restore-time repair one command and
    /// working-directory policy instead of allowing each persistence owner to reconstruct it.
    func resumeBindingSnapshot() -> SurfaceResumeBindingSnapshot? {
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: kind.rawValue,
            runtimeCwd: workingDirectory,
            launchWorkingDirectory: launchCommand?.workingDirectory
        )
        guard let command = resumeCommand(
            includeWorkingDirectoryPrefix: true,
            restoringWorkingDirectory: resolvedWorkingDirectory
        ) else {
            return nil
        }
        return SurfaceResumeBindingSnapshot(
            name: agentDisplayName,
            kind: kind.rawValue,
            command: command,
            cwd: resolvedWorkingDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: launchCommand?.environment,
            launchCommand: launchCommand,
            permissionMode: permissionMode,
            autoResume: true
        )
    }
}
