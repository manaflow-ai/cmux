import CMUXAgentLaunch
import Foundation

extension SurfaceResumeBindingSnapshot {
    func retargetingWorkingDirectory(_ workingDirectory: String?) -> SurfaceResumeBindingSnapshot {
        guard isAgentHookBinding else { return self }
        // Generic restore/transfer cwd is not an authenticated remote observation.
        if restoreWorkingDirectorySelection?.discardsRecordedCwdOptions == true {
            return self
        }
        let normalizedCwd = Self.normalized(workingDirectory)
        var retargeted = self
        let normalizedKind = Self.normalized(kind)
        retargeted.command = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: command,
            previousWorkingDirectory: cwd,
            workingDirectory: normalizedCwd,
            agentKind: normalizedKind
        )
        retargeted.cwd = normalizedCwd
        if var launchCommand = retargeted.launchCommand {
            launchCommand.workingDirectory = normalizedCwd
            retargeted.launchCommand = launchCommand
        }
        // Preserve the recorded policy; only the remote registration boundary
        // may promote a reported directory to an authoritative selection.
        return retargeted
    }
}
