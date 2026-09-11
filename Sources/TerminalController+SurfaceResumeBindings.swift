import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

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
        // A hook can replace the live binding after this surface was restored,
        // while the restore-time agent snapshot still names the previous
        // conversation. Reuse the session-restore identity gate so the record
        // returned to the CLI always agrees with the binding that generated its
        // typed `cmux restore`/`cmux fork` selector.
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
            return controlSurfaceAgentContinuationRecord(
                agent: compatibleAgent.snapshot,
                source: compatibleAgent.source,
                restoredWorkingDirectory: compatibleAgent.restoredWorkingDirectory,
                binding: binding,
                compatibilityBinding: compatibilityBinding
            )
        }
        guard let binding else { return nil }
        return controlSurfaceBindingContinuationRecord(
            binding: binding,
            compatibilityBinding: compatibilityBinding,
            restoredAgentExists: restoredAgent != nil && binding.isAgentHookBinding
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
            // A same-session agent-hook write cannot demote a trusted binding.
            // Report the binding the surface kept rather than a set failure, so
            // an older Pi extension's follow-up verification still sees its
            // own session and third-party tooling reads the effective state.
            if let keptBinding = target.binding,
               effectiveBinding.downgradesTrustedAgentHookBinding(keptBinding) {
                return .result(surfaceResumeSnapshot(target: target, binding: keptBinding, cleared: false))
            }
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
