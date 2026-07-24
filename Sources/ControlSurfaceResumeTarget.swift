import AppKit
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

    @discardableResult
    func setBinding(_ binding: SurfaceResumeBindingSnapshot) -> Bool {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            workspace.setSurfaceResumeBinding(binding, panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            dock.setSurfaceResumeBinding(binding, panelId: surfaceID)
        }
    }

    func clearBinding() {
        switch self {
        case .workspace(_, let workspace, let surfaceID):
            _ = workspace.clearSurfaceResumeBinding(panelId: surfaceID)
        case .dock(_, let dock, let surfaceID):
            _ = dock.clearSurfaceResumeBinding(panelId: surfaceID)
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
            binding: controlResumeBinding(from: binding)
        )
    }

    private func surfaceResumeBindingWithApproval(
        _ binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        let existingRecord = SurfaceResumeApprovalStore.matchingRecord(for: binding)
        var effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        if let promptlessCLIManualBinding = SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: existingRecord
        ) {
            return promptlessCLIManualBinding
        }
        guard SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: existingRecord,
            isMainThread: Thread.isMainThread,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        ) else {
            return effectiveBinding
        }
        let policy = surfacePromptForResumeApproval(binding: effectiveBinding)
        guard let record = SurfaceResumeApprovalStore.approve(binding: binding, policy: policy) else {
            return effectiveBinding
        }
        effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return effectiveBinding
    }

    private func surfacePromptForResumeApproval(
        binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeApprovalPolicy {
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
        let content = CmuxAlertContent(
            flattenedText: informativeText,
            separatingScrollableDetails: binding.command
        )
        content.apply(to: alert, presentingWindow: nil)

        return switch alert.runModal() {
        case .alertFirstButtonReturn: .auto
        case .alertSecondButtonReturn: .prompt
        default: .manual
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
        guard let locatedBinding = target.registeredBinding(binding, inputs: inputs) else {
            return .setFailed
        }
        let effectiveBinding = surfaceResumeBindingWithApproval(locatedBinding)
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
        return .result(surfaceResumeSnapshot(target: target, binding: target.binding, cleared: false))
    }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?
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
        let currentBinding = target.binding
        if let expectedCheckpointID, currentBinding?.checkpointId != expectedCheckpointID {
            return .result(surfaceResumeSnapshot(target: target, binding: currentBinding, cleared: false))
        }
        if let expectedSource, currentBinding?.source != expectedSource {
            return .result(surfaceResumeSnapshot(target: target, binding: currentBinding, cleared: false))
        }
        target.clearBinding()
        return .result(surfaceResumeSnapshot(target: target, binding: nil, cleared: true))
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
