import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 surface resume binding methods
extension TerminalController {
    func v2SurfaceResumeSet(params: [String: Any]) -> V2CallResult {
        if let error = v2SurfaceResumeTargetValidationError(params: params) {
            return error
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: Self.v2WindowUnavailableMessage, data: nil)
        }
        guard let command = v2RawString(params, "command")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .err(code: "invalid_params", message: "Missing command", data: nil)
        }

        let source = v2PublicSurfaceResumeSource(params)
        let binding = SurfaceResumeBindingSnapshot(
            name: v2OptionalTrimmedRawString(params, "name"),
            kind: v2OptionalTrimmedRawString(params, "kind"),
            command: command,
            cwd: v2OptionalTrimmedRawString(params, "cwd"),
            checkpointId: v2OptionalTrimmedRawString(params, "checkpoint_id") ?? v2OptionalTrimmedRawString(params, "checkpointId"),
            source: source,
            environment: v2StringMap(params, "environment"),
            autoResume: source == "agent-hook" ? (v2Bool(params, "auto_resume") ?? false) : false,
            updatedAt: Date().timeIntervalSince1970
        )

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to set resume binding", data: nil)
        v2MainSync {
            guard let target = v2ResolveSurfaceResumeTarget(params: params, fallbackTabManager: tabManager) else {
                result = .err(code: "not_found", message: "Surface not found", data: nil)
                return
            }
            let effectiveBinding = v2SurfaceResumeBindingWithApproval(binding)
            guard target.workspace.setSurfaceResumeBinding(effectiveBinding, panelId: target.surfaceId) else {
                result = .err(code: "invalid_params", message: "Resume command is empty", data: nil)
                return
            }
            result = .ok(v2SurfaceResumeResult(
                tabManager: target.tabManager,
                workspace: target.workspace,
                surfaceId: target.surfaceId,
                binding: effectiveBinding,
                cleared: false
            ))
        }
        return result
    }

    private func v2SurfaceResumeBindingWithApproval(_ binding: SurfaceResumeBindingSnapshot) -> SurfaceResumeBindingSnapshot {
        let existingRecord = SurfaceResumeApprovalStore.matchingRecord(for: binding)
        var effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        if let promptlessCLIManualBinding = SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: existingRecord
        ) {
            return promptlessCLIManualBinding
        }
        guard v2ShouldPromptForSurfaceResumeApproval(binding: binding, existingRecord: existingRecord) else {
            return effectiveBinding
        }
        let policy = v2PromptForSurfaceResumeApproval(binding: effectiveBinding)
        guard let record = SurfaceResumeApprovalStore.approve(binding: binding, policy: policy) else {
            return effectiveBinding
        }
        effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        effectiveBinding.approvalPolicy = record.policy
        effectiveBinding.approvalRecordId = record.id
        effectiveBinding.autoResume = record.policy == .auto
        return effectiveBinding
    }

    private func v2ShouldPromptForSurfaceResumeApproval(
        binding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    ) -> Bool {
        SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: existingRecord,
            isMainThread: Thread.isMainThread,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
    }

    private func v2PromptForSurfaceResumeApproval(
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

    func v2SurfaceResumeGet(params: [String: Any]) -> V2CallResult {
        if let error = v2SurfaceResumeTargetValidationError(params: params) {
            return error
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: Self.v2WindowUnavailableMessage, data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let target = v2ResolveSurfaceResumeTarget(params: params, fallbackTabManager: tabManager) else {
                result = .err(code: "not_found", message: "Surface not found", data: nil)
                return
            }
            result = .ok(v2SurfaceResumeResult(
                tabManager: target.tabManager,
                workspace: target.workspace,
                surfaceId: target.surfaceId,
                binding: target.workspace.surfaceResumeBinding(panelId: target.surfaceId),
                cleared: false
            ))
        }
        return result
    }

    func v2SurfaceResumeClear(params: [String: Any]) -> V2CallResult {
        if let error = v2SurfaceResumeTargetValidationError(params: params) {
            return error
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: Self.v2WindowUnavailableMessage, data: nil)
        }

        let expectedCheckpointId = v2OptionalTrimmedRawString(params, "checkpoint_id")
            ?? v2OptionalTrimmedRawString(params, "checkpointId")
        let expectedSource = v2OptionalTrimmedRawString(params, "source")
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let target = v2ResolveSurfaceResumeTarget(params: params, fallbackTabManager: tabManager) else {
                result = .err(code: "not_found", message: "Surface not found", data: nil)
                return
            }
            let currentBinding = target.workspace.surfaceResumeBinding(panelId: target.surfaceId)
            if let expectedCheckpointId, currentBinding?.checkpointId != expectedCheckpointId {
                result = .ok(v2SurfaceResumeResult(
                    tabManager: target.tabManager,
                    workspace: target.workspace,
                    surfaceId: target.surfaceId,
                    binding: currentBinding,
                    cleared: false
                ))
                return
            }
            if let expectedSource, currentBinding?.source != expectedSource {
                result = .ok(v2SurfaceResumeResult(
                    tabManager: target.tabManager,
                    workspace: target.workspace,
                    surfaceId: target.surfaceId,
                    binding: currentBinding,
                    cleared: false
                ))
                return
            }
            _ = target.workspace.clearSurfaceResumeBinding(panelId: target.surfaceId)
            result = .ok(v2SurfaceResumeResult(
                tabManager: target.tabManager,
                workspace: target.workspace,
                surfaceId: target.surfaceId,
                binding: nil,
                cleared: true
            ))
        }
        return result
    }

    private func v2PublicSurfaceResumeSource(_ params: [String: Any]) -> String? {
        let source = v2OptionalTrimmedRawString(params, "source")
        return source == "process-detected" ? "manual" : source
    }

    private static let v2WindowUnavailableMessage = "cmux window is not available. Reopen the window and try again."

    private func v2SurfaceResumeTargetValidationError(params: [String: Any]) -> V2CallResult? {
        for key in ["window_id", "workspace_id", "surface_id", "tab_id"] {
            if v2HasNonNullParam(params, key), v2UUID(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        return nil
    }

    @MainActor
    private func v2ResolveSurfaceResumeTarget(
        params: [String: Any],
        fallbackTabManager: TabManager
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID)? {
        if let explicitSurfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            if let explicitWorkspaceId = v2UUID(params, "workspace_id") {
                guard let workspace = fallbackTabManager.tabs.first(where: { $0.id == explicitWorkspaceId }),
                      workspace.terminalPanel(for: explicitSurfaceId) != nil else {
                    return nil
                }
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }

            if v2UUID(params, "window_id") != nil {
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
            if let workspace = v2ResolveWorkspace(params: params, tabManager: fallbackTabManager),
               workspace.terminalPanel(for: explicitSurfaceId) != nil {
                return (fallbackTabManager, workspace, explicitSurfaceId)
            }
            return nil
        }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: fallbackTabManager),
              let surfaceId = workspace.focusedPanelId,
              workspace.terminalPanel(for: surfaceId) != nil else {
            return nil
        }
        return (fallbackTabManager, workspace, surfaceId)
    }

    private func v2SurfaceResumeResult(
        tabManager: TabManager,
        workspace: Workspace,
        surfaceId: UUID,
        binding: SurfaceResumeBindingSnapshot?,
        cleared: Bool
    ) -> [String: Any] {
        let paneId = workspace.paneId(forPanelId: surfaceId)?.id
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "pane_id": v2OrNull(paneId?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: paneId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "cleared": cleared,
            "resume_binding": v2SurfaceResumeBindingPayload(binding)
        ]
    }

    func v2SurfaceResumeBindingPayload(_ binding: SurfaceResumeBindingSnapshot?) -> Any {
        guard let binding else { return NSNull() }
        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        return [
            "name": v2OrNull(effectiveBinding.name),
            "kind": v2OrNull(effectiveBinding.kind),
            "command": effectiveBinding.command,
            "cwd": v2OrNull(effectiveBinding.cwd),
            "checkpoint_id": v2OrNull(effectiveBinding.checkpointId),
            "source": v2OrNull(effectiveBinding.source),
            "environment": v2OrNull(effectiveBinding.environment),
            "auto_resume": effectiveBinding.allowsAutomaticResume,
            "approval_policy": v2OrNull(effectiveBinding.approvalPolicy?.rawValue),
            "approval_record_id": v2OrNull(effectiveBinding.approvalRecordId),
            "updated_at": effectiveBinding.updatedAt
        ]
    }

}
