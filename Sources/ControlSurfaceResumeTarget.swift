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

    func acceptsAgentMutationGuard(
        _ guardValue: ControlSidebarAgentMutationGuard
    ) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            return ControlSidebarPanelOwner.workspace(workspace)
                .acceptsAgentMutationGuard(guardValue, panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            return ControlSidebarPanelOwner.dock(dock)
                .acceptsAgentMutationGuard(guardValue, panelId: surfaceID)
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
            _ = workspace.clearSurfaceResumeBinding(panelId: surfaceID)
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
            return binding.registeredForPersistentSSH(context)
        case .dock(_, let dock, let surfaceID):
            guard let registration = dock.persistentSSHResumeRegistration(panelId: surfaceID),
                  remoteWorkspaceID == registration.context.workspaceID,
                  WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteResumeParameters(
                      relayParameters.mapValues(\.foundationObject),
                      remoteRelayTokenHex: registration.relayToken
                  ) else {
                return nil
            }
            return binding.registeredForPersistentSSH(registration.context)
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
        cleared: Bool
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
                : controlSurfaceRestoreRecord(target: target, binding: binding)
        )
    }

    private func controlSurfaceRestoreRecord(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceRestoreRecord? {
        // Structured fields remain untouched; only the explicit legacy fallback
        // receives restore-time provider refreshes that older records depended on.
        let compatibilityBinding = binding.map {
            Workspace.makeSessionRestorePolicyService()
                .bindingForCompatibilityShellRestore($0)
        }
        // A hook can replace the live binding after this surface was restored,
        // while the restore-time agent snapshot still names the previous
        // conversation. Reuse the session-restore identity gate so the record
        // returned to the CLI always agrees with the binding that generated its
        // typed `cmux restore <kind> <checkpoint>` selector.
        let compatibleAgent: SessionRestorableAgentSnapshot? =
            if binding == nil || binding?.isAgentHookBinding == true {
                Workspace.restorableAgentForSessionRestore(
                    target.restorableAgent,
                    resumeBinding: binding
                )
            } else {
                nil
            }
        if let agent = compatibleAgent {
            let launchCommand = binding?.launchCommand ?? agent.launchCommand
            let workingDirectory = target.restoredResumeWorkingDirectory
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
            return ControlSurfaceRestoreRecord(
                modeRawValue: mode.rawValue,
                kind: agent.kind.rawValue,
                checkpointID: agent.sessionId,
                source: "session-snapshot",
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
                legacyCommand: compatibilityBinding?.inlineStartupInput
            )
        }
        guard let binding else { return nil }
        let trimmedKind = binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = trimmedKind.flatMap { $0.isEmpty ? nil : $0 } ?? "command"
        let mode: AgentRestoreRequestMode = binding.isAgentHookBinding
            ? .resumeAgent
            : .direct
        return ControlSurfaceRestoreRecord(
            modeRawValue: mode.rawValue,
            kind: normalizedKind,
            checkpointID: binding.checkpointId,
            source: binding.source,
            workingDirectory: target.restoredResumeWorkingDirectory
                ?? binding.cwd
                ?? binding.launchCommand?.workingDirectory,
            environment: binding.environment ?? [:],
            launchCommand: binding.launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: normalizedKind
                )
            },
            preparedArguments: mode == .direct ? binding.launchCommand?.arguments : nil,
            preparedArgumentsWorkingDirectory: nil,
            permissionMode: binding.permissionMode,
            legacyCommand: compatibilityBinding?.inlineStartupInput
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
                    capturedAt: $0.capturedAt,
                    source: $0.source
                )
            },
            permissionMode: inputs.permissionMode,
            autoResume: inputs.autoResume,
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
        if let agentMutationGuard = inputs.agentMutationGuard,
           !target.acceptsAgentMutationGuard(agentMutationGuard) {
            return .setFailed
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
        if let agentMutationGuard = inputs.agentMutationGuard,
           !target.acceptsAgentMutationGuard(agentMutationGuard) {
            return .setFailed
        }
        guard target.setBinding(effectiveBinding) else {
            return .emptyResumeCommand
        }
        return .result(surfaceResumeSnapshot(target: target, binding: effectiveBinding, cleared: false))
    }

    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool
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
        return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
    }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?,
        agentSessionEnded: Bool,
        expectedBindingUpdatedAt: Double?,
        agentMutationGuard: ControlSidebarAgentMutationGuard?
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
        if let agentMutationGuard,
           !target.acceptsAgentMutationGuard(agentMutationGuard) {
            return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
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
        if let expectedBindingUpdatedAt,
           let bindingForClear,
           bindingForClear.updatedAt != expectedBindingUpdatedAt {
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
