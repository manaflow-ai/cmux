import CMUXAgentLaunch
import Foundation

extension SessionRestorableAgentSnapshot {
    private enum SnapshotCodingKeys: String, CodingKey {
        case kind
        case sessionId
        case workingDirectory
        case launchCommand
        case registration
        case permissionMode
        case hadActivePromptTurn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKeys.self)
        let persistedKind = try container.decode(String.self, forKey: .kind)
        let registration = try container.decodeIfPresent(
            SessionPersistedVaultAgentRegistration.self,
            forKey: .registration
        )?.registration
        guard let kind = RestorableAgentKind(
            persistedRawValue: persistedKind,
            registration: registration
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid restorable agent kind '\(persistedKind)'"
            )
        }
        self.init(
            kind: kind,
            sessionId: try container.decode(String.self, forKey: .sessionId),
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            launchCommand: try container.decodeIfPresent(
                AgentLaunchCommandSnapshot.self,
                forKey: .launchCommand
            ),
            registration: registration,
            // Optional so snapshots persisted before the field decode unchanged.
            permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode),
            hadActivePromptTurn: try container.decodeIfPresent(Bool.self, forKey: .hadActivePromptTurn)
        )
    }

    /// Claude's `cmux restore` command is a deferred-tool continuation. A
    /// normally completed conversation has no active prompt turn to continue,
    /// so it must use the native `claude --resume` launch instead.
    func sessionRestoreStartupInput(
        useLocalRestoreVerb: Bool = true,
        restoringWorkingDirectory: String? = nil
    ) -> String? {
        sessionRestoreStartupInput(
            useLocalRestoreVerb: useLocalRestoreVerb,
            workingDirectorySelection: .recordedFallback(preferred: restoringWorkingDirectory)
        )
    }

    func sessionRestoreStartupInput(
        useLocalRestoreVerb: Bool,
        workingDirectorySelection: RestorableAgentWorkingDirectorySelection
    ) -> String? {
        resumeStartupInput(
            useLocalRestoreVerb: useLocalRestoreVerb &&
                (kind != .claude || hadActivePromptTurn == true),
            workingDirectorySelection: workingDirectorySelection
        )
    }

    /// A validated Claude hook binding is enough to resume a normally ended
    /// conversation. Other agents retain the persisted process-liveness gate.
    static func shouldAutoResumeNormallyEndedClaude(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> Bool {
        guard let restorableAgent,
              restorableAgent.kind == .claude,
              restorableAgent.hadActivePromptTurn != true,
              let resumeBinding,
              resumeBinding.isAgentHookBinding,
              resumeBinding.allowsAutomaticResume,
              let checkpointID = resumeBinding.checkpointId,
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: RestorableAgentKind.claude.rawValue,
                  lhs: checkpointID,
                  rhs: restorableAgent.sessionId
              ) else {
            return false
        }
        guard let bindingKind = resumeBinding.kind,
              RestorableAgentKind(
                  persistedRawValue: bindingKind,
                  registration: restorableAgent.registration
              )?.rawValue == RestorableAgentKind.claude.rawValue else {
            return false
        }
        return true
    }

    var resumeCommand: String? {
        resumeCommand(includeWorkingDirectoryPrefix: true)
    }

    func resumeCommand(
        includeWorkingDirectoryPrefix: Bool,
        restoringWorkingDirectory: String? = nil
    ) -> String? {
        resumeCommand(
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            workingDirectorySelection: .recordedFallback(preferred: restoringWorkingDirectory)
        )
    }

    func resumeCommand(
        includeWorkingDirectoryPrefix: Bool,
        workingDirectorySelection: RestorableAgentWorkingDirectorySelection
    ) -> String? {
        let effectiveWorkingDirectory = workingDirectorySelection.resolved(
            snapshotWorkingDirectory: workingDirectory,
            launchWorkingDirectory: launchCommand?.workingDirectory
        )
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: launchCommand,
                resolvedWorkingDirectory: effectiveWorkingDirectory,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
            )
        }
        return AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            resolvedWorkingDirectory: effectiveWorkingDirectory,
            discardRecordedCwdOptions: workingDirectorySelection.discardsRecordedCwdOptions,
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            observedPermissionMode: permissionMode
        )
    }

    var forkCommand: String? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration,
            observedPermissionMode: permissionMode
        )
    }

    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}
