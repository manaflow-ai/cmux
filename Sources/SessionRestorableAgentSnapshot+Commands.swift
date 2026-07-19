import Foundation

extension SessionRestorableAgentSnapshot {
    private enum SnapshotCodingKeys: String, CodingKey {
        case kind
        case sessionId
        case transcriptPath
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
        )?.migratedPersistedBuiltInRegistration
        if let registration {
            guard registration.id == kind.rawValue else {
                throw DecodingError.dataCorruptedError(
                    forKey: .registration,
                    in: container,
                    debugDescription: "Embedded Vault registration id '\(registration.id)' does not match restorable agent kind '\(kind.rawValue)'"
                )
            }
            // Registry snapshots encode `.custom(id)` as the same string as a
            // native compatibility case. Restore custom ownership for every
            // registry-owned id so its persisted registration continues to
            // define resume and fork behavior after app relaunch.
            if kind.customAgentID == nil {
                guard RestorableAgentKind.registryOwnedRawValues.contains(registration.id) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .registration,
                        in: container,
                        debugDescription: "Embedded Vault registration cannot override native agent kind '\(kind.rawValue)'"
                    )
                }
                kind = .custom(registration.id)
            }
        }
        self.init(
            kind: kind,
            sessionId: try container.decode(String.self, forKey: .sessionId),
            transcriptPath: try container.decodeIfPresent(String.self, forKey: .transcriptPath),
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
            transcriptPath: transcriptPath,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration,
            observedPermissionMode: permissionMode
        )
    }

    var resumeExecutionDescriptor: AgentCommandExecutionDescriptor? {
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().executionDescriptor(
                kind: kind,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
        }
        return AgentResumeCommandBuilder.resumeExecutionDescriptor(
            kind: kind,
            sessionId: sessionId,
            transcriptPath: transcriptPath,
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

    var forkExecutionDescriptor: AgentCommandExecutionDescriptor? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkExecutionDescriptor(
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

extension SurfaceResumeBindingSnapshot {
    var agentHookExecutionDescriptor: AgentCommandExecutionDescriptor? {
        guard isAgentHookBinding else { return nil }
        return AgentResumeCommandBuilder.surfaceResumeBindingExecutionDescriptor(
            command: command,
            kind: kind,
            environment: environment,
            workingDirectory: cwd
        )
    }
}
