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
        case restoreWorkingDirectorySelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKeys.self)
        let persistedKind = try container.decode(String.self, forKey: .kind)
        let registration = try container.decodeIfPresent(
            CmuxVaultAgentRegistration.self,
            forKey: .registration
        )?.migratedPersistedBuiltInRegistration
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
            restoreWorkingDirectorySelection: try container.decodeIfPresent(
                AgentRestoreWorkingDirectorySelection.self,
                forKey: .restoreWorkingDirectorySelection
            )
        )
    }

    var resumeCommand: String? {
        resumeCommand(includeWorkingDirectoryPrefix: true)
    }

    /// Returns a copy whose persisted cwd state cannot outlive the supplied trust decision.
    func applyingRestoreWorkingDirectorySelection(
        _ proposedSelection: AgentRestoreWorkingDirectorySelection
    ) -> SessionRestorableAgentSnapshot {
        let selection = effectiveRestoreWorkingDirectorySelection(proposedSelection)
        var constrained = self
        switch selection {
        case .recordedFallback:
            constrained.restoreWorkingDirectorySelection = selection
        case .exact:
            let workingDirectory = selection.resolved(
                snapshotWorkingDirectory: nil,
                launchWorkingDirectory: nil
            )
            constrained.workingDirectory = workingDirectory
            constrained.restoreWorkingDirectorySelection = .exact(workingDirectory)
            constrained.launchCommand = constrainedLaunchCommand(
                launchCommand,
                selection: .exact(workingDirectory)
            )
        case .unavailable:
            constrained.workingDirectory = nil
            constrained.restoreWorkingDirectorySelection = .unavailable
            constrained.launchCommand = constrainedLaunchCommand(
                launchCommand,
                selection: .unavailable
            )
        }
        return constrained
    }

    /// Returns a copy refreshed from a provenance-validated remote snapshot selection.
    func refreshingAuthoritativeRestoreWorkingDirectorySelection(
        _ proposedSelection: AgentRestoreWorkingDirectorySelection
    ) -> SessionRestorableAgentSnapshot {
        let selection = restoreWorkingDirectorySelection?.refreshedByAuthoritativeRemoteSelection(
            proposedSelection
        ) ?? proposedSelection
        var refreshable = self
        refreshable.restoreWorkingDirectorySelection = nil
        return refreshable.applyingRestoreWorkingDirectorySelection(selection)
    }

    /// Applies a binding's explicit cwd policy over stale snapshot state.
    func applyingAuthoritativeBindingSelection(
        _ selection: AgentRestoreWorkingDirectorySelection
    ) -> SessionRestorableAgentSnapshot {
        var unscoped = self
        unscoped.restoreWorkingDirectorySelection = nil
        return unscoped.applyingRestoreWorkingDirectorySelection(selection)
    }

    /// Resolves an entrypoint request against the stricter policy retained on the snapshot.
    func effectiveRestoreWorkingDirectorySelection(
        _ proposedSelection: AgentRestoreWorkingDirectorySelection
    ) -> AgentRestoreWorkingDirectorySelection {
        let selected = restoreWorkingDirectorySelection?.restricted(by: proposedSelection)
            ?? proposedSelection
        guard registration?.cwd == .ignore else { return selected }
        return selected.permitsResume ? .exact(nil) : .unavailable
    }

    /// Removes captured cwd state from a launch override when the retained policy requires it.
    func constrainedLaunchCommand(
        _ candidate: AgentLaunchCommandSnapshot?,
        selection: AgentRestoreWorkingDirectorySelection
    ) -> AgentLaunchCommandSnapshot? {
        guard selection.discardsRecordedCwdOptions, var candidate else {
            return candidate
        }
        candidate.arguments = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
            from: candidate.arguments,
            workingDirectory: nil,
            agentKind: kind.rawValue,
            removeAllWorkingDirectoryOptions: true
        )
        candidate.workingDirectory = nil
        return candidate
    }

    func preparedResumeArguments(
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        observedPermissionMode: String?
    ) -> [String]? {
        preparedResumeArguments(
            launchCommand: launchCommand,
            workingDirectorySelection: .recordedFallback(preferred: workingDirectory),
            observedPermissionMode: observedPermissionMode
        )
    }

    func preparedResumeArguments(
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectorySelection: AgentRestoreWorkingDirectorySelection,
        observedPermissionMode: String?
    ) -> [String]? {
        let selection = effectiveRestoreWorkingDirectorySelection(workingDirectorySelection)
        guard selection.permitsResume else { return nil }
        let effectiveLaunchCommand = constrainedLaunchCommand(
            launchCommand,
            selection: selection
        )
        let workingDirectory = selection.resolved(
            snapshotWorkingDirectory: self.workingDirectory,
            launchWorkingDirectory: effectiveLaunchCommand?.workingDirectory
        )
        return AgentResumeCommandBuilder().resumeArguments(
            kind: kind,
            sessionId: sessionId,
            launchCommand: effectiveLaunchCommand,
            workingDirectory: workingDirectory,
            customRegistration: registration,
            observedPermissionMode: observedPermissionMode
        )
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
        workingDirectorySelection: AgentRestoreWorkingDirectorySelection
    ) -> String? {
        let selection = effectiveRestoreWorkingDirectorySelection(workingDirectorySelection)
        guard selection.permitsResume else { return nil }
        let effectiveLaunchCommand = constrainedLaunchCommand(
            launchCommand,
            selection: selection
        )
        let effectiveWorkingDirectory = selection.resolved(
            snapshotWorkingDirectory: workingDirectory,
            launchWorkingDirectory: effectiveLaunchCommand?.workingDirectory
        )
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: effectiveLaunchCommand,
                resolvedWorkingDirectory: effectiveWorkingDirectory,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
            )
        }
        return AgentResumeCommandBuilder().resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: effectiveLaunchCommand,
            resolvedWorkingDirectory: effectiveWorkingDirectory,
            discardRecordedCwdOptions: selection.discardsRecordedCwdOptions,
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            observedPermissionMode: permissionMode
        )
    }

    var forkCommand: String? {
        guard kind.restoreMode == .resumeSession else { return nil }
        let selection = effectiveRestoreWorkingDirectorySelection(
            .recordedFallback(preferred: nil)
        )
        guard selection.permitsResume else { return nil }
        let effectiveLaunchCommand = constrainedLaunchCommand(
            launchCommand,
            selection: selection
        )
        let effectiveWorkingDirectory = selection.resolved(
            snapshotWorkingDirectory: workingDirectory,
            launchWorkingDirectory: effectiveLaunchCommand?.workingDirectory
        )
        return AgentResumeCommandBuilder().forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: effectiveLaunchCommand,
            resolvedWorkingDirectory: effectiveWorkingDirectory,
            discardRecordedCwdOptions: selection.discardsRecordedCwdOptions,
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
    /// Rebuilds an explicit restore command from structured launch data, or fails closed.
    func constrainedRestoreCommand(
        selection: AgentRestoreWorkingDirectorySelection,
        includeWorkingDirectoryPrefix: Bool,
        registration: CmuxVaultAgentRegistration?
    ) -> String? {
        guard case .exact = selection,
              let rawKind = kind,
              let agentKind = RestorableAgentKind(
                  persistedRawValue: rawKind,
                  registration: registration
              ),
              let sessionId = checkpointId,
              let launchCommand,
              registration != nil || agentKind.customAgentID == nil else {
            return nil
        }
        var structuredLaunchCommand = launchCommand
        if let bindingEnvironment = environment, !bindingEnvironment.isEmpty {
            var mergedEnvironment = structuredLaunchCommand.environment ?? [:]
            mergedEnvironment.merge(bindingEnvironment) { _, bindingValue in bindingValue }
            structuredLaunchCommand.environment = mergedEnvironment.isEmpty ? nil : mergedEnvironment
        }
        let agent = SessionRestorableAgentSnapshot(
            kind: agentKind,
            sessionId: sessionId,
            workingDirectory: cwd,
            launchCommand: structuredLaunchCommand,
            registration: registration,
            permissionMode: permissionMode
        ).applyingAuthoritativeBindingSelection(selection)
        guard let command = agent.resumeCommand(
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            workingDirectorySelection: selection
        ) else {
            return nil
        }
        return AgentRestoreLaunch(kind: agentKind.rawValue, sessionID: sessionId)?
            .applying(toStoredCommand: command) ?? command
    }

    /// Carries an agent snapshot's cwd trust boundary onto its persisted hook binding.
    func applyingRestoreWorkingDirectorySelection(
        _ selection: AgentRestoreWorkingDirectorySelection,
        from agent: SessionRestorableAgentSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        let effectiveSelection: AgentRestoreWorkingDirectorySelection
        switch restoreWorkingDirectorySelection {
        case .exact(let workingDirectory):
            effectiveSelection = .exact(workingDirectory)
        case .unavailable:
            effectiveSelection = .unavailable
        case .recordedFallback, nil:
            effectiveSelection = selection
        }
        var constrained = self
        constrained.restoreWorkingDirectorySelection = effectiveSelection

        guard effectiveSelection.permitsResume else {
            return constrained.invalidatingAgentRestoreRecipe()
        }

        var bindingAgent = agent
        bindingAgent.launchCommand = launchCommand ?? agent.launchCommand
        bindingAgent.permissionMode = permissionMode ?? agent.permissionMode
        let constrainedAgent = bindingAgent.applyingAuthoritativeBindingSelection(effectiveSelection)
        guard let command = constrainedAgent.resumeCommand(
            includeWorkingDirectoryPrefix: true,
            workingDirectorySelection: effectiveSelection
        ) else {
            return constrained.invalidatingAgentRestoreRecipe()
        }

        constrained.command = command
        constrained.cwd = effectiveSelection.resolved(
            snapshotWorkingDirectory: constrainedAgent.workingDirectory,
            launchWorkingDirectory: constrainedAgent.launchCommand?.workingDirectory
        )
        constrained.launchCommand = constrainedAgent.launchCommand
        return constrained
    }

    /// Refreshes a persisted binding from a provenance-validated remote report.
    func applyingAuthoritativeRemoteRestoreWorkingDirectorySelection(
        _ selection: AgentRestoreWorkingDirectorySelection,
        from agent: SessionRestorableAgentSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        var refreshed = self
        refreshed.restoreWorkingDirectorySelection = nil
        return refreshed.applyingRestoreWorkingDirectorySelection(selection, from: agent)
    }

    /// Removes every persisted field that could reconstruct an unavailable agent restore.
    func invalidatingAgentRestoreRecipe() -> SurfaceResumeBindingSnapshot {
        var invalidated = self
        invalidated.restoreWorkingDirectorySelection = .unavailable
        invalidated.command = ""
        invalidated.cwd = nil
        invalidated.launchCommand = nil
        return invalidated
    }

    /// Preserves a same-session binding's already-constrained restart recipe.
    func inheritingRestoreWorkingDirectorySelection(
        from previous: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        guard let selection = previous.restoreWorkingDirectorySelection else { return self }
        var constrained = self
        constrained.restoreWorkingDirectorySelection = selection
        constrained.command = previous.command
        constrained.cwd = previous.cwd
        constrained.launchCommand = previous.launchCommand
        return constrained
    }
}
