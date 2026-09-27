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
        guard remoteRelayDockTargetIsCurrent(routing: routing, dock: dock, surfaceID: surfaceID) else {
            return nil
        }
        return .dock(tabManager: location.tabManager, dock: dock, surfaceID: surfaceID)
    }

    private func surfaceResumeSnapshot(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot?,
        cleared: Bool,
        claimSucceeded: Bool? = nil,
        approvalRequired: Bool? = nil
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
            resumeClaimed: claimSucceeded,
            approvalRequired: approvalRequired
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
                AgentLaunchEnvironmentPolicy().selectedRestoreRecordEnvironment(
                    from: $0,
                    kind: kind,
                    launcher: command.launcher,
                    arguments: command.arguments
                )
            }
        } ?? command.environment
        return ControlAgentLaunchCommand(
            launcher: command.launcher,
            externalLauncher: command.externalLauncher,
            executablePath: command.executablePath,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory,
            environment: environment,
            verificationHome: command.verificationHome,
            capturedAt: command.capturedAt,
            source: command.source
        )
    }

    /// `surface.resume.set` from the control socket. Never presents approval UI;
    /// see ``SurfaceResumeProposalOrigin``.
    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution {
        setSurfaceResumeBinding(
            routing: routing,
            explicitTargetID: explicitTargetID,
            hasResolvedWindowID: hasResolvedWindowID,
            inputs: inputs,
            origin: .controlSocket
        )
    }

    func setSurfaceResumeBinding(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs,
        origin: SurfaceResumeProposalOrigin
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
                    externalLauncher: $0.externalLauncher,
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
        let approvalRequired: Bool
        switch surfaceResumeBindingWithApproval(locatedBinding, origin: origin) {
        case .pendingSigningSecret:
            return .approvalPending(message: surfaceResumeApprovalPendingMessage)
        case let .resolved(resolved):
            effectiveBinding = resolved.binding
            approvalRequired = resolved.approvalRequired
        }
        guard target.setBinding(effectiveBinding) else {
            // A same-session agent-hook write cannot demote a trusted binding.
            // Report the binding the surface kept rather than a set failure, so
            // an older Pi extension's follow-up verification still sees its
            // own session and third-party tooling reads the effective state.
            if let keptBinding = target.binding,
               effectiveBinding.downgradesTrustedAgentHookBinding(keptBinding) {
                return .result(surfaceResumeSnapshot(
                    target: target,
                    binding: keptBinding,
                    cleared: false,
                    approvalRequired: false
                ))
            }
            return .emptyResumeCommand
        }
        return .result(surfaceResumeSnapshot(
            target: target,
            binding: effectiveBinding,
            cleared: false,
            approvalRequired: approvalRequired
        ))
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
    /// Returns the binding that owns agent-resume semantics for a surface.
    /// Dock terminals keep this managed binding separately from a transient
    /// process/tmux binding that may currently be effective for ``get``.
    func controlSurfaceManagedAgentResumeBinding(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let target = resolveSurfaceResumeTarget(
                  routing: routing,
                  explicitTargetID: explicitTargetID,
                  hasResolvedWindowID: hasResolvedWindowID,
                  fallbackTabManager: tabManager
              ) else {
            return nil
        }
        switch target {
        case .workspace:
            return target.binding?.isAgentHookBinding == true ? target.binding : nil
        case .dock(_, let dock, let surfaceID):
            return dock.managedAgentResumeBinding(panelId: surfaceID)
        }
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
