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
        var kind = try container.decode(RestorableAgentKind.self, forKey: .kind)
        let registration = try container.decodeIfPresent(
            CmuxVaultAgentRegistration.self,
            forKey: .registration
        )
        // Registry-detected snapshots persist `.custom(id)`, whose raw string
        // collapses to the native case on decode when the id matches a
        // built-in raw value. Restore the write-side identity whenever that
        // collapse would change restore semantics (relaunch-only natives such
        // as Ollama), so a stored custom registration keeps owning resume.
        if kind.restoreMode == .relaunchCommand,
           let registration,
           registration.id == kind.rawValue {
            kind = .custom(registration.id)
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
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
        }
        return AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration,
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
