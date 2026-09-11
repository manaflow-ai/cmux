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
    ) -> ControlSurfaceRestoreRecord? {
        guard binding?.restoreWorkingDirectorySelection?.permitsResume != false else {
            return nil
        }
        let bindingScopedAgent: SessionRestorableAgentSnapshot = if let bindingSelection =
            binding?.restoreWorkingDirectorySelection,
            bindingSelection.discardsRecordedCwdOptions {
            agent.applyingAuthoritativeBindingSelection(bindingSelection)
        } else {
            agent
        }
        let workingDirectorySelection = bindingScopedAgent.effectiveRestoreWorkingDirectorySelection(
            .recordedFallback(preferred: restoredWorkingDirectory ?? binding?.cwd)
        )
        guard workingDirectorySelection.permitsResume else { return nil }
        let launchCommand = bindingScopedAgent.constrainedLaunchCommand(
            binding?.launchCommand ?? bindingScopedAgent.launchCommand,
            selection: workingDirectorySelection
        )
        let workingDirectory = workingDirectorySelection.resolved(
            snapshotWorkingDirectory: bindingScopedAgent.workingDirectory,
            launchWorkingDirectory: launchCommand?.workingDirectory
        )
        let permissionMode = binding?.permissionMode ?? agent.permissionMode
        let mode: AgentRestoreRequestMode = bindingScopedAgent.kind.restoreMode == .relaunchCommand
            ? .relaunchAgent
            : .resumeAgent
        let preparedArguments = bindingScopedAgent.kind.restoreMode == .resumeSession
            ? bindingScopedAgent.preparedResumeArguments(
                launchCommand: launchCommand,
                workingDirectorySelection: workingDirectorySelection,
                observedPermissionMode: permissionMode
            )
            : nil
        let legacyCommand = binding?.restoreWorkingDirectorySelection?.discardsRecordedCwdOptions != true &&
            bindingScopedAgent.restoreWorkingDirectorySelection?.discardsRecordedCwdOptions != true
            ? compatibilityBinding?.inlineStartupInput
            : nil
        guard bindingScopedAgent.kind.customAgentID == nil ||
                preparedArguments?.isEmpty == false ||
                legacyCommand != nil else {
            return nil
        }
        let forkArguments = bindingScopedAgent.preparedForkArguments(
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: permissionMode
        )
        return ControlSurfaceRestoreRecord(
            modeRawValue: mode.rawValue,
            kind: bindingScopedAgent.kind.rawValue,
            checkpointID: bindingScopedAgent.sessionId,
            source: source,
            workingDirectory: workingDirectory,
            environment: binding?.environment ?? [:],
            launchCommand: launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: bindingScopedAgent.kind.rawValue
                )
            },
            preparedArguments: preparedArguments,
            preparedArgumentsWorkingDirectory: preparedArguments == nil
                ? nil
                : workingDirectory,
            permissionMode: permissionMode,
            legacyCommand: legacyCommand,
            forkArguments: forkArguments,
            forkArgumentsWorkingDirectory: forkArguments == nil ? nil : workingDirectory,
            legacyForkCommand: bindingScopedAgent.forkCommand(
                restoringWorkingDirectory: workingDirectory
            )
        )
    }

    /// Builds a continuation record after a live binding supersedes a snapshot.
    func controlSurfaceBindingContinuationRecord(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot,
        compatibilityBinding: SurfaceResumeBindingSnapshot?,
        restoredAgentExists: Bool
    ) -> ControlSurfaceRestoreRecord? {
        let trimmedKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = trimmedKind.flatMap { $0.isEmpty ? nil : $0 } ?? "command"
        let bindingSelection = binding.restoreWorkingDirectorySelection
        let isUnscopedCustomAgentHook = binding.isAgentHookBinding &&
            bindingSelection == nil &&
            RestorableAgentKind(rawValue: normalizedKind)?.customAgentID != nil
        guard !isUnscopedCustomAgentHook else { return nil }
        guard bindingSelection?.permitsResume != false else { return nil }
        let mode: AgentRestoreRequestMode
        if let kind = RestorableAgentKind(rawValue: normalizedKind),
           kind.restoreMode == .relaunchCommand {
            mode = .relaunchAgent
        } else {
            mode = binding.isAgentHookBinding ? .resumeAgent : .direct
        }
        // A superseded snapshot cannot authorize its registry template. Rebuild
        // only native argv from the binding that now owns the surface.
        let workingDirectory: String? = if let bindingSelection {
            bindingSelection.resolved(
                snapshotWorkingDirectory: binding.cwd,
                launchWorkingDirectory: binding.launchCommand?.workingDirectory
            )
        } else {
            target.restoredResumeWorkingDirectory
                ?? binding.cwd
                ?? binding.launchCommand?.workingDirectory
        }
        let launchCommand: AgentLaunchCommandSnapshot?
        if let bindingSelection,
           bindingSelection.discardsRecordedCwdOptions,
           var command = binding.launchCommand {
            let builtInAgentKind = target.builtInAgentKindForBindingSanitization(
                binding: binding,
                normalizedKind: normalizedKind
            )
            command.arguments = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: command.arguments,
                workingDirectory: nil,
                agentKind: builtInAgentKind,
                removeAllWorkingDirectoryOptions: true
            )
            command.workingDirectory = nil
            launchCommand = command
        } else {
            launchCommand = binding.launchCommand
        }
        let preparedArguments = restoredAgentExists
            ? preparedResumeArguments(
                binding: binding,
                launchCommand: launchCommand,
                normalizedKind: normalizedKind,
                workingDirectory: workingDirectory
            )
            : nil
        let forkArguments = restoredAgentExists
            ? preparedForkArguments(
                binding: binding,
                launchCommand: launchCommand,
                normalizedKind: normalizedKind,
                workingDirectory: workingDirectory
            )
            : nil
        let legacyCommand = bindingSelection?.discardsRecordedCwdOptions == true
            ? nil
            : compatibilityBinding?.inlineStartupInput
        guard !binding.isAgentHookBinding ||
                RestorableAgentKind(rawValue: normalizedKind)?.customAgentID == nil ||
                preparedArguments?.isEmpty == false ||
                legacyCommand != nil else {
            return nil
        }
        return ControlSurfaceRestoreRecord(
            modeRawValue: mode.rawValue,
            kind: normalizedKind,
            checkpointID: binding.checkpointId,
            source: binding.source,
            workingDirectory: workingDirectory,
            environment: binding.environment ?? [:],
            launchCommand: launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: normalizedKind
                )
            },
            preparedArguments: mode == .direct
                ? launchCommand?.arguments
                : preparedArguments,
            preparedArgumentsWorkingDirectory: preparedArguments == nil
                ? nil
                : workingDirectory,
            permissionMode: binding.permissionMode,
            legacyCommand: legacyCommand,
            forkArguments: forkArguments,
            forkArgumentsWorkingDirectory: forkArguments == nil ? nil : workingDirectory,
            legacyForkCommand: nil
        )
    }

    private func preparedResumeArguments(
        binding: SurfaceResumeBindingSnapshot,
        launchCommand: AgentLaunchCommandSnapshot?,
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
            launchCommand: launchCommand,
            permissionMode: binding.permissionMode
        ).preparedResumeArguments(
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: binding.permissionMode
        )
    }

    private func preparedForkArguments(
        binding: SurfaceResumeBindingSnapshot,
        launchCommand: AgentLaunchCommandSnapshot?,
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
            launchCommand: launchCommand,
            permissionMode: binding.permissionMode
        ).preparedForkArguments(
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            observedPermissionMode: binding.permissionMode
        )
    }
}
