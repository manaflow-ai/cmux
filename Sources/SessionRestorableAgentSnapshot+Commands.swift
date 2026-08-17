import Foundation

extension SessionRestorableAgentSnapshot {
    private enum SnapshotCodingKeys: String, CodingKey {
        case kind
        case sessionId
        case workingDirectory
        case launchCommand
        case registration
        case permissionMode
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
            permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode)
        )
    }

    var resumeCommand: String? {
        resumeCommand(includeWorkingDirectoryPrefix: true)
    }

    func resumeCommand(
        includeWorkingDirectoryPrefix: Bool,
        restoringWorkingDirectory: String? = nil
    ) -> String? {
        let effectiveWorkingDirectory = restoringWorkingDirectory ?? workingDirectory
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: launchCommand,
                workingDirectory: effectiveWorkingDirectory,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
            )
        }
        return AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: effectiveWorkingDirectory,
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
