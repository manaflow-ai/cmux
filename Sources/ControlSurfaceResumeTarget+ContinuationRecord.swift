import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Builds a continuation record from the compatible restored-agent snapshot.
    func controlSurfaceAgentContinuationRecord(
        agent: SessionRestorableAgentSnapshot,
        source: String,
        restoredWorkingDirectory: String?,
        binding: SurfaceResumeBindingSnapshot?,
        compatibilityBinding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceRestoreRecord {
        let launchCommand = binding?.launchCommand ?? agent.launchCommand
        let workingDirectory = restoredWorkingDirectory
            ?? binding?.cwd
            ?? agent.workingDirectory
            ?? launchCommand?.workingDirectory
        let permissionMode = binding?.permissionMode ?? agent.permissionMode
        let mode: AgentRestoreRequestMode = agent.kind.restoreMode == .relaunchCommand
            ? .relaunchAgent
            : .resumeAgent
        let preparedArguments = agent.kind.restoreMode == .resumeSession
            ? agent.preparedResumeArguments(
                launchCommand: launchCommand,
                workingDirectory: workingDirectory,
                observedPermissionMode: permissionMode
            )
            : nil
        let forkArguments = agent.preparedForkArguments(
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: permissionMode
        )
        return ControlSurfaceRestoreRecord(
            modeRawValue: mode.rawValue,
            kind: agent.kind.rawValue,
            checkpointID: agent.sessionId,
            source: source,
            workingDirectory: workingDirectory,
            environment: binding?.environment ?? [:],
            launchCommand: launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: agent.kind.rawValue
                )
            },
            preparedArguments: preparedArguments,
            preparedArgumentsWorkingDirectory: preparedArguments == nil
                ? nil
                : workingDirectory,
            permissionMode: permissionMode,
            legacyCommand: compatibilityBinding?.inlineStartupInput,
            forkArguments: forkArguments,
            forkArgumentsWorkingDirectory: forkArguments == nil ? nil : workingDirectory,
            legacyForkCommand: agent.forkCommand(
                restoringWorkingDirectory: workingDirectory
            )
        )
    }

    /// Builds a continuation record after a live binding supersedes a snapshot.
    func controlSurfaceBindingContinuationRecord(
        binding: SurfaceResumeBindingSnapshot,
        compatibilityBinding: SurfaceResumeBindingSnapshot?,
        restoredAgentExists: Bool
    ) -> ControlSurfaceRestoreRecord {
        let trimmedKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = trimmedKind.flatMap { $0.isEmpty ? nil : $0 } ?? "command"
        let mode: AgentRestoreRequestMode
        if let kind = RestorableAgentKind(rawValue: normalizedKind),
           kind.restoreMode == .relaunchCommand {
            mode = .relaunchAgent
        } else {
            mode = binding.isAgentHookBinding ? .resumeAgent : .direct
        }
        // A superseded snapshot cannot authorize its registry template. Rebuild
        // only native argv from the binding that now owns the surface.
        let workingDirectory = binding.cwd ?? binding.launchCommand?.workingDirectory
        let preparedArguments = restoredAgentExists
            ? preparedResumeArguments(
                binding: binding,
                normalizedKind: normalizedKind,
                workingDirectory: workingDirectory
            )
            : nil
        let forkArguments = restoredAgentExists
            ? preparedForkArguments(
                binding: binding,
                normalizedKind: normalizedKind,
                workingDirectory: workingDirectory
            )
            : nil
        return ControlSurfaceRestoreRecord(
            modeRawValue: mode.rawValue,
            kind: normalizedKind,
            checkpointID: binding.checkpointId,
            source: binding.source,
            workingDirectory: workingDirectory,
            environment: binding.environment ?? [:],
            launchCommand: binding.launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: normalizedKind
                )
            },
            preparedArguments: mode == .direct
                ? binding.launchCommand?.arguments
                : preparedArguments,
            preparedArgumentsWorkingDirectory: preparedArguments == nil
                ? nil
                : workingDirectory,
            permissionMode: binding.permissionMode,
            legacyCommand: compatibilityBinding?.inlineStartupInput,
            forkArguments: forkArguments,
            forkArgumentsWorkingDirectory: forkArguments == nil ? nil : workingDirectory,
            legacyForkCommand: nil
        )
    }

    private func preparedResumeArguments(
        binding: SurfaceResumeBindingSnapshot,
        normalizedKind: String,
        workingDirectory: String?
    ) -> [String]? {
        guard binding.isAgentHookBinding,
              let checkpointID = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointID.isEmpty else {
            return nil
        }
        // Registry templates belong to the rejected snapshot. Only native,
        // non-overridable kinds can be reconstructed from the live binding.
        guard let kind = RestorableAgentKind(rawValue: normalizedKind),
              RestorableAgentKind.allCases.contains(kind),
              kind.restoreMode == .resumeSession else {
            return nil
        }
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: checkpointID,
            workingDirectory: workingDirectory,
            launchCommand: binding.launchCommand,
            permissionMode: binding.permissionMode
        ).preparedResumeArguments(
            launchCommand: binding.launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: binding.permissionMode
        )
    }

    private func preparedForkArguments(
        binding: SurfaceResumeBindingSnapshot,
        normalizedKind: String,
        workingDirectory: String?
    ) -> [String]? {
        guard binding.isAgentHookBinding,
              let kind = RestorableAgentKind(rawValue: normalizedKind),
              RestorableAgentKind.allCases.contains(kind),
              kind.restoreMode == .resumeSession,
              let checkpointID = binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointID.isEmpty else {
            return nil
        }
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: checkpointID,
            workingDirectory: workingDirectory,
            launchCommand: binding.launchCommand,
            permissionMode: binding.permissionMode
        ).preparedForkArguments(
            launchCommand: binding.launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: binding.permissionMode
        )
    }
}
