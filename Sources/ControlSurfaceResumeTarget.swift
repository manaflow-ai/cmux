import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

@MainActor
enum ControlSurfaceResumeTarget {
    case workspace(tabManager: TabManager, workspace: Workspace, surfaceID: UUID)
    case dock(tabManager: TabManager, dock: DockSplitStore, surfaceID: UUID)

    var tabManager: TabManager {
        switch self {
        case .workspace(let tabManager, _, _), .dock(let tabManager, _, _): tabManager
        }
    }

    var surfaceID: UUID {
        switch self {
        case .workspace(_, _, let surfaceID), .dock(_, _, let surfaceID): surfaceID
        }
    }

    var workspaceID: UUID {
        switch self {
        case .workspace(_, let workspace, _): workspace.id
        case .dock(_, let dock, _): dock.workspaceId
        }
    }

    var paneID: UUID? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.paneId(forPanelId: surfaceID)?.id
        case .dock(_, let dock, let surfaceID):
            dock.paneId(forPanelId: surfaceID)?.id
        }
    }

    var binding: SurfaceResumeBindingSnapshot? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.surfaceResumeBinding(panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            dock.surfaceResumeBinding(panelId: surfaceID)
        }
    }

    var restorableAgent: SessionRestorableAgentSnapshot? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.restoredAgentSnapshotsByPanelId[surfaceID]
        case .dock(_, let dock, let surfaceID):
            dock.restoredAgentLifecycle.snapshotsByPanelId[surfaceID]
        }
    }

    var restoredResumeWorkingDirectory: String? {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.restoredResumeSessionWorkingDirectoriesByPanelId[surfaceID]
        case .dock(_, let dock, let surfaceID):
            dock.restoredResumeSessionWorkingDirectoriesByPanelId[surfaceID]
        }
    }

    @discardableResult
    func setBinding(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.setSurfaceResumeBinding(binding, panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            dock.setSurfaceResumeBinding(binding, panelId: surfaceID)
        }
    }

    /// Atomically claims the current binding generation for a CLI restore.
    func claimBinding(
        expectedCheckpointID: String,
        expectedSource: String,
        expectedUpdatedAt: TimeInterval
    ) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.claimSurfaceResumeBinding(
                panelId: surfaceID,
                expectedCheckpointID: expectedCheckpointID,
                expectedSource: expectedSource,
                expectedUpdatedAt: expectedUpdatedAt
            )
        case .dock(_, let dock, let surfaceID):
            dock.claimSurfaceResumeBinding(
                panelId: surfaceID,
                expectedCheckpointID: expectedCheckpointID,
                expectedSource: expectedSource,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }
    }

    func bindingForClear(
        expectedSource: String?,
        agentSessionEnded: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        switch self {
        case .workspace:
            return binding
        case .dock(_, let dock, let surfaceID):
            if expectedSource == "agent-hook" || agentSessionEnded {
                return dock.managedAgentResumeBinding(panelId: surfaceID)
            }
            return binding
        }
    }

    func clearBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        agentSessionEnded: Bool
    ) {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            _ = workspace.clearSurfaceResumeBinding(
                panelId: surfaceID,
                agentSessionEnded: agentSessionEnded
            )
        case .dock(_, let dock, let surfaceID):
            _ = dock.clearSurfaceResumeBinding(
                panelId: surfaceID,
                binding: binding,
                agentSessionEnded: agentSessionEnded
            )
        }
    }

    func registeredBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        inputs: ControlSurfaceResumeSetInputs
    ) -> SurfaceResumeBindingSnapshot? {
        guard let remoteWorkspaceID = inputs.remoteWorkspaceID else { return binding }
        guard let relayParameters = inputs.remoteRelayParameters else { return nil }

        switch self {
        case .workspace(_, let workspace, let surfaceID):
            guard remoteWorkspaceID == workspace.id,
                  WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                      relayParameters.mapValues(\.foundationObject),
                      remoteRelayTokenHex: workspace.remoteConfiguration?.relayToken
                  ),
                  let context = workspace.persistentSSHResumeContext(panelID: surfaceID) else {
                return nil
            }
            return binding.registeredForPersistentSSH(
                context,
                restorableAgent: self.restorableAgent
            )
        case .dock(_, let dock, let surfaceID):
            guard let registration = dock.persistentSSHResumeRegistration(panelId: surfaceID),
                  remoteWorkspaceID == registration.context.workspaceID,
                  WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                      relayParameters.mapValues(\.foundationObject),
                      remoteRelayTokenHex: registration.relayToken
                  ) else {
                return nil
            }
            return binding.registeredForPersistentSSH(
                registration.context,
                restorableAgent: self.restorableAgent
            )
        }
    }
}

extension SurfaceResumeBindingSnapshot {
    /// Applies the single app-owned Codex provenance invariant atomically with
    /// the surface binding mutation. Bindings created before provenance was
    /// persisted may establish or refresh another legacy binding, but cannot
    /// replace a binding that carries classified evidence.
    func allowsCodexAgentHookReplacement(of existing: SurfaceResumeBindingSnapshot?) -> Bool {
        guard isAgentHookBinding, kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" else {
            return true
        }
        if resumeEvidenceProvenance == nil {
            guard let existing else { return true }
            let existingKind = existing.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let existingIsLegacyCodex = existing.isAgentHookBinding && existingKind == nil
            guard existingKind == "codex" || existingIsLegacyCodex else {
                return true
            }
            return existing.isAgentHookBinding
                && existing.resumeEvidenceProvenance == nil
        }
        guard let incoming = codexResumeEvidenceProvenance,
              incoming.mayOwnBinding else { return false }
        guard let existing else {
            return true
        }
        let existingKind = existing.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingIsLegacyCodex = existing.isAgentHookBinding && existingKind == nil
        guard existingKind == "codex" || existingIsLegacyCodex else {
            return true
        }
        guard let previous = existing.codexResumeEvidenceProvenance else {
            return incoming == .tui
        }
        return incoming.canReplace(previous)
    }

    private var codexResumeEvidenceProvenance: AgentResumeEvidenceProvenance? {
        switch resumeEvidenceProvenance?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "exec": .exec
        case "subagent": .subagent
        case "unknown": .unknown
        case "tui": .tui
        default: nil
        }
    }
}

extension TerminalController {
    private func resolveSurfaceResumeTarget(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        fallbackTabManager: TabManager
    ) -> ControlSurfaceResumeTarget? {
        if let explicitSurfaceID = explicitTargetID {
            if let explicitWorkspaceID = routing.workspaceID,
               let workspace = fallbackTabManager.tabs.first(where: { $0.id == explicitWorkspaceID }),
               workspace.terminalPanel(for: explicitSurfaceID) != nil {
                return .workspace(
                    tabManager: fallbackTabManager,
                    workspace: workspace,
                    surfaceID: explicitSurfaceID
                )
            }
            if let dockTarget = resolveDockSurfaceResumeTarget(
                routing: routing,
                surfaceID: explicitSurfaceID,
                hasResolvedWindowID: hasResolvedWindowID,
                fallbackTabManager: fallbackTabManager
            ) {
                return dockTarget
            }
            if routing.workspaceID != nil { return nil }
            if hasResolvedWindowID {
                guard let workspace = fallbackTabManager.tabs.first(where: {
                    $0.terminalPanel(for: explicitSurfaceID) != nil
                }) else {
                    return nil
                }
                return .workspace(
                    tabManager: fallbackTabManager,
                    workspace: workspace,
                    surfaceID: explicitSurfaceID
                )
            }
            if let located = AppDelegate.shared?.locateSurface(surfaceId: explicitSurfaceID),
               let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
               workspace.terminalPanel(for: explicitSurfaceID) != nil {
                return .workspace(
                    tabManager: located.tabManager,
                    workspace: workspace,
                    surfaceID: explicitSurfaceID
                )
            }
            if let workspace = fallbackTabManager.tabs.first(where: {
                $0.terminalPanel(for: explicitSurfaceID) != nil
            }) {
                return .workspace(
                    tabManager: fallbackTabManager,
                    workspace: workspace,
                    surfaceID: explicitSurfaceID
                )
            }
            if let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: fallbackTabManager),
               workspace.terminalPanel(for: explicitSurfaceID) != nil {
                return .workspace(
                    tabManager: fallbackTabManager,
                    workspace: workspace,
                    surfaceID: explicitSurfaceID
                )
            }
            return nil
        }

        if let dock = windowDockForRouting(routing, tabManager: fallbackTabManager),
           let surfaceID = dock.focusedPanelId,
           dock.panels[surfaceID] is TerminalPanel {
            return .dock(tabManager: dockOwnerTabManager(for: dock, fallback: fallbackTabManager), dock: dock, surfaceID: surfaceID)
        }
        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: fallbackTabManager),
              let surfaceID = workspace.focusedPanelId,
              workspace.terminalPanel(for: surfaceID) != nil else {
            return nil
        }
        return .workspace(tabManager: fallbackTabManager, workspace: workspace, surfaceID: surfaceID)
    }

    private func resolveDockSurfaceResumeTarget(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        hasResolvedWindowID: Bool,
        fallbackTabManager: TabManager
    ) -> ControlSurfaceResumeTarget? {
        guard let dock = DockSplitStore.liveStores.first(where: {
            $0.containsPanel(surfaceID) && $0.panels[surfaceID] is TerminalPanel
        }),
        let location = locateDockSurface(surfaceID) else {
            return nil
        }
        if hasResolvedWindowID, location.tabManager !== fallbackTabManager { return nil }
        if let explicitWorkspaceID = routing.workspaceID {
            switch dock.scope {
            case .workspace:
                guard explicitWorkspaceID == dock.workspaceId else { return nil }
            case .global:
                if AppDelegate.isWindowDockRoutingId(explicitWorkspaceID),
                   windowDockMismatchesExplicitSelectors(
                       routing,
                       dock: dock,
                       aliasTabManager: fallbackTabManager
                   ) {
                    return nil
                }
            }
        }
        return .dock(tabManager: location.tabManager, dock: dock, surfaceID: surfaceID)
    }

    private func surfaceResumeSnapshot(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot?,
        cleared: Bool,
        claimSucceeded: Bool? = nil
    ) -> ControlSurfaceResumeSnapshot {
        ControlSurfaceResumeSnapshot(
            windowID: target.windowID(using: self),
            workspaceID: target.workspaceID,
            paneID: target.paneID,
            surfaceID: target.surfaceID,
            cleared: cleared,
            binding: controlResumeBinding(from: binding),
            restoreRecord: cleared
                ? nil
                : controlSurfaceRestoreRecord(target: target, binding: binding),
            resumeClaimed: claimSucceeded
        )
    }

    func controlSurfaceRestoreRecord(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceRestoreRecord? {
        // Structured fields remain untouched; only the explicit legacy fallback
        // receives restore-time provider refreshes that older records depended on.
        let compatibilityBinding = binding.map {
            Workspace.makeSessionRestorePolicyService()
                .bindingForCompatibilityShellRestore($0)
        }
        guard binding?.restoreWorkingDirectorySelection?.permitsResume != false else {
            return nil
        }
        // A hook can replace the live binding after this surface was restored,
        // while the restore-time agent snapshot still names the previous
        // conversation. Reuse the session-restore identity gate so the record
        // returned to the CLI always agrees with the binding that generated its
        // typed `cmux restore <kind> <checkpoint>` selector.
        let restoredAgent = target.restorableAgent
        let compatibleAgent: (
            snapshot: SessionRestorableAgentSnapshot,
            source: String,
            restoredWorkingDirectory: String?
        )?
        if binding == nil || binding?.isAgentHookBinding == true {
            if let restoredAgent = Workspace.restorableAgentForSessionRestore(
                restoredAgent,
                resumeBinding: binding
            ) {
                compatibleAgent = (
                    restoredAgent,
                    "session-snapshot",
                    target.restoredResumeWorkingDirectory
                )
            } else {
                compatibleAgent = nil
            }
        } else {
            compatibleAgent = nil
        }
        if let compatibleAgent {
            let agent = compatibleAgent.snapshot
            let bindingScopedAgent: SessionRestorableAgentSnapshot = if let bindingSelection =
                binding?.restoreWorkingDirectorySelection,
                bindingSelection.discardsRecordedCwdOptions {
                agent.applyingAuthoritativeBindingSelection(bindingSelection)
            } else {
                agent
            }
            let workingDirectorySelection = bindingScopedAgent.effectiveRestoreWorkingDirectorySelection(
                .recordedFallback(preferred: target.restoredResumeWorkingDirectory ?? binding?.cwd)
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
            let permissionMode = binding?.permissionMode ?? bindingScopedAgent.permissionMode
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
            return ControlSurfaceRestoreRecord(
                modeRawValue: mode.rawValue,
                kind: bindingScopedAgent.kind.rawValue,
                checkpointID: bindingScopedAgent.sessionId,
                source: compatibleAgent.source,
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
                legacyCommand: binding?.restoreWorkingDirectorySelection?.discardsRecordedCwdOptions != true &&
                    bindingScopedAgent.restoreWorkingDirectorySelection?.discardsRecordedCwdOptions != true
                    ? compatibilityBinding?.inlineStartupInput
                    : nil
            )
        }
        guard binding?.isAgentHookBinding != true ||
                target.restorableAgent?.restoreWorkingDirectorySelection == nil else {
            return nil
        }
        guard let binding else { return nil }
        let trimmedKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = trimmedKind.flatMap { $0.isEmpty ? nil : $0 } ?? "command"
        let bindingSelection = binding.restoreWorkingDirectorySelection
        let isUnscopedCustomAgentHook = binding.isAgentHookBinding &&
            bindingSelection == nil &&
            RestorableAgentKind(rawValue: normalizedKind)?.customAgentID != nil
        // A custom Vault registration may explicitly ignore cwd tracking, but
        // the registration is unavailable once its matching snapshot is gone.
        // Do not replay the captured shell command without that policy proof.
        guard !isUnscopedCustomAgentHook else { return nil }
        guard bindingSelection?.permitsResume != false else { return nil }
        // An explicit `.exact(nil)` is a real, authoritative choice—not a
        // missing value. Keep the optional selection branch separate so the
        // fallback cwd rescue is consulted only for legacy bindings that have
        // no policy at all.
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
            command.arguments = AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                from: command.arguments,
                workingDirectory: nil,
                agentKind: normalizedKind,
                removeAllWorkingDirectoryOptions: true
            )
            command.workingDirectory = nil
            launchCommand = command
        } else {
            launchCommand = binding.launchCommand
        }
        let mode: AgentRestoreRequestMode = binding.isAgentHookBinding
            ? .resumeAgent
            : .direct
        // Once a newer hook binding supersedes a restored agent snapshot, none
        // of the rejected snapshot's identity-scoped restore data may leak into
        // the record. Rebuild the typed argv from the authoritative binding so
        // `cmux restore` keeps its shell-free path even during that handoff.
        let preparedArguments: [String]?
        if restoredAgent != nil {
            preparedArguments = preparedResumeArguments(
                binding: binding,
                normalizedKind: normalizedKind,
                workingDirectory: workingDirectory
            )
        } else {
            preparedArguments = nil
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
            legacyCommand: bindingSelection?.discardsRecordedCwdOptions == true
                ? nil
                : compatibilityBinding?.inlineStartupInput
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
        // A rejected session snapshot cannot authorize its persisted custom-agent
        // template. Registry-owned kinds also fall back to the current binding's
        // compatibility command; only native, non-overridable kinds have enough
        // information here to rebuild shell-free argv safely.
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

    func controlAgentLaunchCommand(
        _ command: AgentLaunchCommandSnapshot,
        replaySafeEnvironmentFor kind: String? = nil
    ) -> ControlAgentLaunchCommand {
        let environment = kind.flatMap { kind in
            command.environment.map {
                AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
                    from: $0,
                    kind: kind
                )
            }
        } ?? command.environment
        return ControlAgentLaunchCommand(
            launcher: command.launcher,
            executablePath: command.executablePath,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory,
            environment: environment,
            verificationHome: command.verificationHome,
            capturedAt: command.capturedAt,
            source: command.source
        )
    }

    private func surfaceResumeBindingWithApproval(
        _ binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeApprovalLookup<SurfaceResumeBindingSnapshot> {
        let context: (
            effectiveBinding: SurfaceResumeBindingSnapshot,
            existingRecord: SurfaceResumeApprovalRecord?
        )
        switch SurfaceResumeApprovalStore.approvalProposalContext(for: binding) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case let .resolved(resolvedContext):
            context = resolvedContext
        }
        var effectiveBinding = context.effectiveBinding
        if let promptlessCLIManualBinding = SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: context.existingRecord
        ) {
            return .resolved(promptlessCLIManualBinding)
        }
        guard SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: context.existingRecord,
            isMainThread: Thread.isMainThread,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        ) else {
            return .resolved(effectiveBinding)
        }
        let approval = surfacePromptForResumeApproval(binding: effectiveBinding)
        guard let record = SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: approval.policy,
            commandPrefix: approval.commandPrefix
        ) else {
            return .resolved(effectiveBinding)
        }
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return .resolved(effectiveBinding)
    }

    private var surfaceResumeApprovalPendingMessage: String {
        String(
            localized: "surfaceResumeApproval.pending.message",
            defaultValue: "Resume approval data is still loading. Retry the request."
        )
    }

    private func surfacePromptForResumeApproval(
        binding: SurfaceResumeBindingSnapshot
    ) -> (policy: SurfaceResumeApprovalPolicy, commandPrefix: [String]?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "surfaceResumeApproval.proposal.title",
            defaultValue: "Allow Resume Command?"
        )
        let cwd = binding.cwd ?? String(localized: "surfaceResumeApproval.cwd.none", defaultValue: "None")
        let informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.proposal.message",
                defaultValue: "A process wants cmux to keep this resume command for the current terminal:\n\nWorking directory: %@\n\n%@"
            ),
            cwd,
            binding.command
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.auto", defaultValue: "Auto-Restore"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.ask", defaultValue: "Ask Each Time"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.manual", defaultValue: "Keep Manual"))
        let generalizedPrefix = SurfaceResumeCommandCanonicalizer.generalizedApprovalPrefix(
            forCommand: binding.command
        )
        let folderScopedGeneralizedPrefix =
            SurfaceResumeCommandCanonicalizer.normalizedCWD(binding.cwd) == nil
            ? nil
            : generalizedPrefix
        if let generalizedPrefix = folderScopedGeneralizedPrefix {
            let renderedPrefix = generalizedPrefix
                .map(SurfaceResumeCommandCanonicalizer.shellQuoted)
                .joined(separator: " ")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(
                format: String(
                    localized: "surfaceResumeApproval.proposal.applyToPrefix",
                    defaultValue: "Apply to all commands starting with “%@” in this folder"
                ),
                renderedPrefix
            )
        }
        let content = CmuxAlertContent(
            flattenedText: informativeText,
            separatingScrollableDetails: binding.command
        )
        content.apply(to: alert, presentingWindow: nil)

        let response = alert.runModal()
        let commandPrefix = alert.suppressionButton?.state == .on
            ? folderScopedGeneralizedPrefix
            : nil
        return switch response {
        case .alertFirstButtonReturn: (.auto, commandPrefix)
        case .alertSecondButtonReturn: (.prompt, commandPrefix)
        default: (.manual, commandPrefix)
        }
    }

    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .windowUnavailable
        }
        let binding = SurfaceResumeBindingSnapshot(
            name: inputs.name,
            kind: inputs.kind,
            command: inputs.command,
            cwd: inputs.cwd,
            checkpointId: inputs.checkpointID,
            source: inputs.source,
            environment: inputs.environment,
            launchCommand: inputs.launchCommand.map {
                AgentLaunchCommandSnapshot(
                    launcher: $0.launcher,
                    executablePath: $0.executablePath,
                    arguments: $0.arguments,
                    workingDirectory: $0.workingDirectory,
                    environment: $0.environment,
                    verificationHome: $0.verificationHome,
                    capturedAt: $0.capturedAt,
                    source: $0.source
                )
            },
            permissionMode: inputs.permissionMode,
            autoResume: inputs.autoResume,
            resumeEvidenceProvenance: inputs.resumeEvidenceProvenance,
            updatedAt: Date.now.timeIntervalSince1970
        )
        guard let target = resolveSurfaceResumeTarget(
            routing: routing,
            explicitTargetID: explicitTargetID,
            hasResolvedWindowID: hasResolvedWindowID,
            fallbackTabManager: tabManager
        ) else {
            return .surfaceNotFound
        }
        guard let locatedBinding = target.registeredBinding(binding, inputs: inputs) else {
            return .setFailed
        }
        let effectiveBinding: SurfaceResumeBindingSnapshot
        switch surfaceResumeBindingWithApproval(locatedBinding) {
        case .pendingSigningSecret:
            return .approvalPending(message: surfaceResumeApprovalPendingMessage)
        case let .resolved(binding):
            effectiveBinding = binding
        }
        guard target.setBinding(effectiveBinding) else {
            return .emptyResumeCommand
        }
        return .result(surfaceResumeSnapshot(target: target, binding: effectiveBinding, cleared: false))
    }

    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        claimCheckpointID: String?,
        claimSource: String?,
        claimUpdatedAt: Double?
    ) -> ControlSurfaceResumeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .windowUnavailable
        }
        guard let target = resolveSurfaceResumeTarget(
            routing: routing,
            explicitTargetID: explicitTargetID,
            hasResolvedWindowID: hasResolvedWindowID,
            fallbackTabManager: tabManager
        ) else {
            return .surfaceNotFound
        }
        if let binding = target.binding,
           case .pendingSigningSecret = SurfaceResumeApprovalStore.applyingStoredApprovalLookup(to: binding) {
            return .approvalPending(message: surfaceResumeApprovalPendingMessage)
        }
        let claimSucceeded: Bool?
        if let claimCheckpointID, let claimSource, let claimUpdatedAt {
            claimSucceeded = target.claimBinding(
                expectedCheckpointID: claimCheckpointID,
                expectedSource: claimSource,
                expectedUpdatedAt: claimUpdatedAt
            )
        } else {
            claimSucceeded = nil
        }
        return .result(
            surfaceResumeSnapshot(
                target: target,
                binding: target.binding,
                cleared: false,
                claimSucceeded: claimSucceeded
            )
        )
    }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?,
        expectedUpdatedAt: Double?,
        agentSessionEnded: Bool
    ) -> ControlSurfaceResumeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .windowUnavailable
        }
        guard let target = resolveSurfaceResumeTarget(
            routing: routing,
            explicitTargetID: explicitTargetID,
            hasResolvedWindowID: hasResolvedWindowID,
            fallbackTabManager: tabManager
        ) else {
            return .surfaceNotFound
        }
        let bindingForClear = target.bindingForClear(
            expectedSource: expectedSource,
            agentSessionEnded: agentSessionEnded
        )
        if let expectedCheckpointID, bindingForClear?.checkpointId != expectedCheckpointID {
            return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
        }
        if let expectedSource, bindingForClear?.source != expectedSource {
            return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
        }
        if let expectedUpdatedAt,
           !expectedUpdatedAt.isFinite || bindingForClear?.updatedAt != expectedUpdatedAt {
            return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
        }
        target.clearBinding(bindingForClear, agentSessionEnded: agentSessionEnded)
        return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: true))
    }
}

private extension ControlSurfaceResumeTarget {
    func windowID(using controller: TerminalController) -> UUID? {
        switch self {
        case .workspace(let tabManager, _, _):
            controller.v2ResolveWindowId(tabManager: tabManager)
        case .dock(let tabManager, let dock, _):
            controller.dockResultWindowId(for: dock, tabManager: tabManager)
        }
    }
}
