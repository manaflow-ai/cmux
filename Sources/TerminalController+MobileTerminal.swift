import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CmuxTerminal
import Foundation

/// `mobile.terminal.*` data-plane RPC entrypoints on the data-plane god object.
///
/// The terminal create / replay / viewport / scroll / mouse / input /
/// paste_image / paste dispatch logic, and the mobile workspace-create echo, now
/// live in ``MobileTerminalRPCHandler``; this file is the thin seam between it
/// and ``TerminalController``: the handler reaches the terminal data plane (v2
/// param coercion, tab-manager / workspace / surface resolution, the shared
/// validation helpers, the viewport-report state machine, the render-grid and
/// scroll-payload projection, and the ghostty / pasteboard / agent-detection
/// reads) only through the ``MobileTerminalRPCHost`` conformance below, and the
/// entrypoints other callers still drive (the mobile data-plane RPC dispatch,
/// the `mobileHost.*` control-context bridges, and the chat composer's paste
/// reuse) forward to the owned handler. Wire behavior is identical to before the
/// move.
extension TerminalController {
    /// The owned mobile terminal dispatch handler. Built lazily so it captures
    /// `self` as its host seam after the controller is fully constructed; the
    /// live workspace / surface state it drives is resolved through the seam at
    /// call time.
    var mobileTerminalHandler: MobileTerminalRPCHandler {
        if let existing = mobileTerminalHandlerStorage {
            return existing
        }
        let handler = MobileTerminalRPCHandler(host: self)
        mobileTerminalHandlerStorage = handler
        return handler
    }

    /// Mobile workspace-create echo. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/workspaceCreate(params:)``.
    func v2MobileWorkspaceCreate(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.workspaceCreate(params: params)
    }

    /// Mobile terminal create. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalCreate(params:)``.
    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalCreate(params: params)
    }

    /// Mobile terminal replay snapshot. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalReplay(params:)``.
    func v2MobileTerminalReplay(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalReplay(params: params)
    }

    /// Mobile terminal viewport report. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalViewport(params:)``.
    func v2MobileTerminalViewport(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalViewport(params: params)
    }

    /// Mobile terminal scroll. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalScroll(params:)``.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalScroll(params: params)
    }

    /// Mobile terminal mouse click. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalMouse(params:)``.
    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalMouse(params: params)
    }

    /// Mobile terminal text input. Forwards to the owned handler; see
    /// ``MobileTerminalRPCHandler/terminalInput(params:)``.
    func v2MobileTerminalInput(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalInput(params: params)
    }

    /// Mobile terminal pasted-image injection. Forwards to the owned handler;
    /// see ``MobileTerminalRPCHandler/terminalPasteImage(params:)``.
    func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalPasteImage(params: params)
    }

    /// Mobile composer bracketed-paste + submit. Forwards to the owned handler;
    /// see ``MobileTerminalRPCHandler/terminalPaste(params:)``.
    func v2MobileTerminalPaste(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalPaste(params: params)
    }
}

// MARK: - MobileTerminalRPCHost

extension TerminalController: MobileTerminalRPCHost {
    func mobileTerminalResolveTabManager(params: [String: Any]) -> TabManager? {
        v2ResolveTabManager(params: params)
    }

    func mobileTerminalResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        v2ResolveWorkspace(params: params, tabManager: tabManager)
    }

    func mobileTerminalResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (workspace: Workspace, surfaceId: UUID?)? {
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: params,
            requireTerminal: requireTerminal
        ) else { return nil }
        return (workspace: resolved.workspace, surfaceId: resolved.surfaceId)
    }

    func mobileTerminalWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        mobileWorkspaceIDValidationError(params: params)
    }

    // `mobileTerminalAliasValidationError(params:)` is satisfied directly by the
    // existing same-named method on `TerminalController` (relaxed to internal so
    // the witness is visible from this separate conformance file).

    func mobileTerminalWorkspaceCreate(
        params: [String: Any],
        tabManager: TabManager
    ) -> V2CallResult {
        v2WorkspaceCreate(params: params, tabManager: tabManager)
    }

    func mobileTerminalWorkspaceList(
        params: [String: Any],
        tabManager: TabManager?,
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) -> V2CallResult {
        v2MobileWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdWorkspaceID: createdWorkspaceID,
            createdTerminalID: createdTerminalID
        )
    }

    func mobileTerminalDefaultPaneId(in workspace: Workspace) -> UUID? {
        (workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first)?.id
    }

    func mobileTerminalReplayRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64
    ) -> MobileTerminalRenderGridFrame? {
        mobileTerminalRenderGridFrame(terminalPanel: terminalPanel, surfaceID: surfaceID, seq: seq)
    }

    func mobileTerminalScrollPayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any] {
        mobileTerminalScrollResponsePayload(
            workspaceID: workspaceID,
            terminalPanel: terminalPanel,
            surfaceID: surfaceID,
            params: params
        )
    }

    func mobileTerminalActiveVTExportSnapshot(terminalPanel: TerminalPanel) -> String? {
        readTerminalTextFromVTExportForSnapshot(
            terminalPanel: terminalPanel,
            bindingAction: "write_active_file:copy,vt",
            lineLimit: nil,
            normalizeLineEndings: false
        )
    }

    func mobileTerminalLiveGridSize(
        terminalPanel: TerminalPanel,
        reason: String
    ) -> (columns: Int, rows: Int)? {
        guard let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: reason) else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        return (columns: max(Int(size.columns), 1), rows: max(Int(size.rows), 1))
    }

    func mobileTerminalApplyViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool
    ) {
        applyMobileViewportReport(params: params, terminalPanel: terminalPanel, sticky: sticky)
    }

    func mobileTerminalClearViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: reason)
    }

    func mobileTerminalSaveImageData(_ data: Data, format: String) -> String? {
        GhosttyApp.terminalPasteboard.saveImageData(data, fileExtension: format)
    }

    func mobileTerminalIsClaudeCode(panel: TerminalPanel, workspace: Workspace) -> Bool {
        TextBoxAgentDetection.isClaudeCode(
            context: workspace.terminalAgentContext(panel: panel)
        )
    }

    func mobileTerminalRawString(_ params: [String: Any], _ key: String) -> String? {
        v2RawString(params, key)
    }

    func mobileTerminalString(_ params: [String: Any], _ key: String) -> String? {
        v2String(params, key)
    }

    func mobileTerminalBool(_ params: [String: Any], _ key: String) -> Bool? {
        v2Bool(params, key)
    }

    var mobileTerminalInputQueueFullMessage: String { terminalErrorStrings.inputQueueFull }
    var mobileTerminalSurfaceUnavailableMessage: String { terminalErrorStrings.surfaceUnavailable }
    var mobileTerminalProcessExitedMessage: String { terminalErrorStrings.processExited }
}
