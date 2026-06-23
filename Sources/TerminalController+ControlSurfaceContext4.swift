import AppKit
import CmuxRemoteSession
import Bonsplit
import CmuxControlSocket
import Foundation
import CmuxWorkspaces

/// The surface-domain resume (`resume.set` / `.get` / `.clear`) and reporting
/// (`report_tty` / `report_shell_state` / `ports_kick`) witnesses, plus the token
/// parsers. Split out of `TerminalController+ControlSurfaceContext` to keep the
/// conformance readable; see that file's doc comment for the overview. The blocking
/// approval `NSAlert` and its `String(localized:)` calls resolve here, in the app
/// bundle, so translations survive.
extension TerminalController {

    // MARK: - resume target resolution (twin of v2ResolveSurfaceResumeTarget)

    /// The byte-faithful twin of the file-private `v2ResolveSurfaceResumeTarget`,
    /// re-declared here because `private` is file-scoped. It uses the routing
    /// selectors the coordinator already parsed in place of the raw params.
    private func resolveSurfaceResumeTarget(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        fallbackTabManager: TabManager
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID)? {
        // Legacy explicit target: surface_id ?? tab_id ONLY (terminal_id is a
        // general-routing alias but was never a resume target), and the window
        // branch requires a RESOLVABLE window_id (legacy `v2UUID != nil`).
        if let explicitSurfaceId = explicitTargetID {
            if let explicitWorkspaceId = routing.workspaceID {
                guard let workspace = fallbackTabManager.tabs.first(where: { $0.id == explicitWorkspaceId }),
                      workspace.terminalPanel(for: explicitSurfaceId) != nil else {
                    return nil
                }
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }
            if hasResolvedWindowID {
                guard let workspace = fallbackTabManager.tabs.first(where: {
                    $0.terminalPanel(for: explicitSurfaceId) != nil
                }) else {
                    return nil
                }
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }
            if let located = AppDelegate.shared?.locateSurface(surfaceId: explicitSurfaceId),
               let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
               workspace.terminalPanel(for: explicitSurfaceId) != nil {
                return (located.tabManager, workspace, explicitSurfaceId)
            }
            if let workspace = fallbackTabManager.tabs.first(where: {
                $0.terminalPanel(for: explicitSurfaceId) != nil
            }) {
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }
            if let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: fallbackTabManager),
               workspace.terminalPanel(for: explicitSurfaceId) != nil {
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }
            return nil
        }
        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: fallbackTabManager),
              let surfaceId = workspace.focusedPanelId,
              workspace.terminalPanel(for: surfaceId) != nil else {
            return nil
        }
        return (fallbackTabManager, workspace, surfaceId)
    }

    /// Builds the resume snapshot the seam returns, mirroring `v2SurfaceResumeResult`.
    private func surfaceResumeSnapshot(
        tabManager: TabManager,
        workspace: Workspace,
        surfaceId: UUID,
        binding: SurfaceResumeBindingSnapshot?,
        cleared: Bool
    ) -> ControlSurfaceResumeSnapshot {
        ControlSurfaceResumeSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            paneID: workspace.paneId(forPanelId: surfaceId)?.id,
            surfaceID: surfaceId,
            cleared: cleared,
            binding: controlResumeBinding(from: binding)
        )
    }

    // MARK: - resume approval flow (twin of v2SurfaceResumeBindingWithApproval)

    /// The byte-faithful twin of the file-private
    /// `v2SurfaceResumeBindingWithApproval`, re-declared here. Runs the blocking
    /// approval prompt in the app bundle.
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

    /// The byte-faithful twin of the file-private `v2PromptForSurfaceResumeApproval`.
    /// The blocking `NSAlert` and its `String(localized:)` calls resolve here.
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
        alert.informativeText = String(
            format: String(
                localized: "surfaceResumeApproval.proposal.message",
                defaultValue: "A process wants cmux to keep this resume command for the current terminal:\n\n%@\n\nWorking directory: %@"
            ),
            binding.command,
            cwd
        )
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.auto", defaultValue: "Auto-Restore"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.ask", defaultValue: "Ask Each Time"))
        alert.addButton(withTitle: String(localized: "surfaceResumeApproval.proposal.manual", defaultValue: "Keep Manual"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .auto
        case .alertSecondButtonReturn:
            return .prompt
        default:
            return .manual
        }
    }

    // MARK: - resume.set / get / clear

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
            updatedAt: Date().timeIntervalSince1970
        )
        guard let target = resolveSurfaceResumeTarget(
            routing: routing,
            explicitTargetID: explicitTargetID,
            hasResolvedWindowID: hasResolvedWindowID,
            fallbackTabManager: tabManager
        ) else {
            return .surfaceNotFound
        }
        let effectiveBinding = surfaceResumeBindingWithApproval(binding)
        guard target.workspace.setSurfaceResumeBinding(effectiveBinding, panelId: target.surfaceId) else {
            return .emptyResumeCommand
        }
        return .result(surfaceResumeSnapshot(
            tabManager: target.tabManager,
            workspace: target.workspace,
            surfaceId: target.surfaceId,
            binding: effectiveBinding,
            cleared: false
        ))
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
        return .result(surfaceResumeSnapshot(
            tabManager: target.tabManager,
            workspace: target.workspace,
            surfaceId: target.surfaceId,
            binding: target.workspace.surfaceResumeBinding(panelId: target.surfaceId),
            cleared: false
        ))
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
        let currentBinding = target.workspace.surfaceResumeBinding(panelId: target.surfaceId)
        if let expectedCheckpointID, currentBinding?.checkpointId != expectedCheckpointID {
            return .result(surfaceResumeSnapshot(
                tabManager: target.tabManager,
                workspace: target.workspace,
                surfaceId: target.surfaceId,
                binding: currentBinding,
                cleared: false
            ))
        }
        if let expectedSource, currentBinding?.source != expectedSource {
            return .result(surfaceResumeSnapshot(
                tabManager: target.tabManager,
                workspace: target.workspace,
                surfaceId: target.surfaceId,
                binding: currentBinding,
                cleared: false
            ))
        }
        _ = target.workspace.clearSurfaceResumeBinding(panelId: target.surfaceId)
        return .result(surfaceResumeSnapshot(
            tabManager: target.tabManager,
            workspace: target.workspace,
            surfaceId: target.surfaceId,
            binding: nil,
            cleared: true
        ))
    }

    // MARK: - token parsers

    func controlSurfaceParseShellActivityState(_ rawState: String) -> String? {
        PanelShellActivityState.parseReported(rawState)?.rawValue
    }

    func controlSurfaceParsePortScanKickReason(_ rawReason: String) -> String? {
        PortScanKickReason.parseReported(rawReason)?.rawValue
    }

    // MARK: - report_tty

    func controlSurfaceReportTTY(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        ttyName: String
    ) -> ControlSurfaceReportTTYResolution {
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                tab.rememberPendingRemoteSurfaceTTY(ttyName, requestedSurfaceId: requestedSurfaceID)
                return .pending
            }
            return .surfaceNotFound
        }

        tab.surfaceTTYNames[surfaceId] = ttyName
        if tab.isRemoteWorkspace {
            tab.syncRemotePortScanTTYs()
            _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
        } else {
            PortScanner.shared.registerTTY(workspaceId: workspaceID, panelId: surfaceId, ttyName: ttyName)
        }
        return .recorded(surfaceID: surfaceId)
    }

    // MARK: - report_shell_state

    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution {
        guard let state = PanelShellActivityState(rawValue: stateRawValue) else {
            // Unreachable: the coordinator only forwards a value the app produced.
            return .pending
        }
        if let requestedSurfaceID {
            let shouldPublish = socketFastPathState.shouldPublishShellActivity(
                workspaceId: workspaceID,
                panelId: requestedSurfaceID,
                state: state.rawValue
            )
            if shouldPublish {
                DispatchQueue.main.async {
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) else { return }
                    tabManager.updateSurfaceShellActivity(
                        tabId: workspaceID,
                        surfaceId: requestedSurfaceID,
                        state: state
                    )
                }
            }
            return .explicit(surfaceID: requestedSurfaceID, published: shouldPublish)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = self.controlTabForSidebarMutation(id: workspaceID) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            let surfaceId = self.controlResolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceID,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else { return }
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tab.id) else { return }
            tabManager.updateSurfaceShellActivity(tabId: tab.id, surfaceId: surfaceId, state: state)
        }
        return .pending
    }

    // MARK: - ports_kick

    func controlSurfacePortsKick(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        reasonRawValue: String
    ) -> ControlSurfacePortsKickResolution {
        guard let reason = PortScanKickReason(rawValue: reasonRawValue) else {
            // Unreachable: the coordinator only forwards a value the app produced.
            return .workspaceNotFound
        }
        guard let tab = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIds = Set(tab.panels.keys)
        tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

        let surfaceId = controlResolveReportedSurfaceId(
            in: tab,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIds
        )
        guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
            if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                tab.rememberPendingRemoteSurfacePortKick(reason: reason, requestedSurfaceId: requestedSurfaceID)
                return .pending
            }
            return .surfaceNotFound
        }

        if tab.isRemoteWorkspace {
            tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
        } else {
            PortScanner.shared.kick(workspaceId: workspaceID, panelId: surfaceId)
        }
        return .kicked(surfaceID: surfaceId)
    }

    // MARK: - shared report helpers (twins of file-private members)

    /// The byte-faithful twin of the file-private `tabForSidebarMutation(id:)`:
    /// the controller's own TabManager first, then any window's TabManager.
    private func controlTabForSidebarMutation(id: UUID) -> Workspace? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    /// The byte-faithful twin of the file-private `resolveReportedSurfaceId`.
    private func controlResolveReportedSurfaceId(
        in workspace: Workspace,
        requestedSurfaceId: UUID?,
        validSurfaceIds: Set<UUID>
    ) -> UUID? {
        if let requestedSurfaceId {
            guard validSurfaceIds.contains(requestedSurfaceId) else { return nil }
            return requestedSurfaceId
        }
        if let focusedSurfaceId = workspace.focusedPanelId,
           validSurfaceIds.contains(focusedSurfaceId),
           (!workspace.isRemoteWorkspace || workspace.isRemoteTerminalSurface(focusedSurfaceId)) {
            return focusedSurfaceId
        }
        guard workspace.isRemoteWorkspace else { return nil }
        let remoteTerminalSurfaceIds = validSurfaceIds.filter { workspace.isRemoteTerminalSurface($0) }
        if remoteTerminalSurfaceIds.count == 1 {
            return remoteTerminalSurfaceIds.first
        }
        if validSurfaceIds.count == 1 {
            return validSurfaceIds.first
        }
        return nil
    }
}
