import CMUXMobileCore
import CmuxPanes
import Foundation

/// Mobile terminal-IO RPC entrypoints on the data-plane god object.
///
/// The terminal create / replay / viewport / scroll / mouse / input / paste /
/// paste_image dispatch and the mobile `workspace.create` echo now live in
/// ``MobileTerminalRPCHandler``; this file is the thin seam between it and
/// ``TerminalController``: the handler reaches the terminal data plane (param /
/// UUID coercion, tab-manager / workspace / window resolution, the shared
/// workspace-create and workspace-list bodies, the app-coupled render-grid /
/// viewport / VT-export machinery, and the localized terminal error messages)
/// only through the ``MobileTerminalRPCHost`` conformance below. The entrypoints
/// other callers still drive (the v2 control-socket `handleMobileHost` bridge,
/// the chat handler's paste reuse, and the attach-ticket / workspace-list alias
/// and resolution callers) forward to the owned handler, so the wire behavior is
/// identical to before the move.
extension TerminalController {
    /// The owned mobile terminal-IO dispatch handler. Built lazily so it captures
    /// `self` as its host seam after the controller is fully constructed; the
    /// tab-manager, workspace, and viewport machinery it reaches are resolved
    /// through the seam at call time.
    var mobileTerminalHandler: MobileTerminalRPCHandler {
        if let existing = mobileTerminalHandlerStorage {
            return existing
        }
        let handler = MobileTerminalRPCHandler(host: self)
        mobileTerminalHandlerStorage = handler
        return handler
    }

    /// Classifies the `surface_id` / `terminal_id` / `tab_id` terminal alias
    /// triple. Forwards to the owned handler; the attach-ticket and
    /// workspace-list callers still resolve the alias through this name. See
    /// ``MobileTerminalRPCHandler/aliasUUID(params:)``.
    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        mobileTerminalHandler.aliasUUID(params: params)
    }

    /// Resolves a workspace and (optionally) its target terminal surface from RPC
    /// params. Forwards to the owned handler; the attach-ticket and chat callers
    /// still resolve through this name. See
    /// ``MobileTerminalRPCHandler/resolveWorkspaceAndSurface(params:requireTerminal:)``.
    func mobileResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID?)? {
        mobileTerminalHandler.resolveWorkspaceAndSurface(params: params, requireTerminal: requireTerminal)
    }

    /// The terminal panels of `workspace` in display order. Forwards to the owned
    /// handler; the workspace-list serializer still enumerates through this name.
    /// See ``MobileTerminalRPCHandler/terminalPanels(in:)``.
    func mobileTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        mobileTerminalHandler.terminalPanels(in: workspace)
    }

    /// Mobile `workspace.create` echo. Forwards to the owned handler; the v2
    /// control-socket `handleMobileHost` bridge drives this name. See
    /// ``MobileTerminalRPCHandler/workspaceCreate(params:)``.
    func v2MobileWorkspaceCreate(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.workspaceCreate(params: params)
    }

    /// Mobile terminal create. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalCreate(params:)``.
    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalCreate(params: params)
    }

    /// Mobile terminal replay. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalReplay(params:)``.
    func v2MobileTerminalReplay(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalReplay(params: params)
    }

    /// Mobile terminal viewport report. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalViewport(params:)``.
    func v2MobileTerminalViewport(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalViewport(params: params)
    }

    /// Mobile terminal scroll. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalScroll(params:)``.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalScroll(params: params)
    }

    /// Mobile terminal mouse. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalMouse(params:)``.
    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalMouse(params: params)
    }

    /// Mobile terminal input. Forwards to the owned handler; the v2
    /// control-socket bridge drives this name. See
    /// ``MobileTerminalRPCHandler/terminalInput(params:)``.
    func v2MobileTerminalInput(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalInput(params: params)
    }

    /// Mobile terminal paste (bracketed block + submit). Forwards to the owned
    /// handler; the v2 control-socket bridge and the chat handler drive this
    /// name. See ``MobileTerminalRPCHandler/terminalPaste(params:)``.
    func v2MobileTerminalPaste(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalPaste(params: params)
    }

    /// Mobile terminal image paste. Forwards to the owned handler; the v2
    /// control-socket bridge and the chat handler drive this name. See
    /// ``MobileTerminalRPCHandler/terminalPasteImage(params:)``.
    func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {
        mobileTerminalHandler.terminalPasteImage(params: params)
    }
}

// MARK: - MobileTerminalRPCHost

extension TerminalController: MobileTerminalRPCHost {
    func mobileTerminalHasNonNullParam(_ params: [String: Any], _ key: String) -> Bool {
        v2HasNonNullParam(params, key)
    }

    func mobileTerminalUUID(_ params: [String: Any], _ key: String) -> UUID? {
        v2UUID(params, key)
    }

    func mobileTerminalStringParam(_ params: [String: Any], _ key: String) -> String? {
        v2String(params, key)
    }

    func mobileTerminalRawStringParam(_ params: [String: Any], _ key: String) -> String? {
        v2RawString(params, key)
    }

    func mobileTerminalBoolParam(_ params: [String: Any], _ key: String) -> Bool? {
        v2Bool(params, key)
    }

    func mobileTerminalResolveTabManager(params: [String: Any]) -> TabManager? {
        v2ResolveTabManager(params: params)
    }

    func mobileTerminalResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        v2ResolveWorkspace(params: params, tabManager: tabManager)
    }

    func mobileTerminalWorkspaceCreate(params: [String: Any], tabManager: TabManager?) -> V2CallResult {
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

    func mobileTerminalWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard let error = mobileWorkspaceIDValidation(params: params).validationError else {
            return nil
        }
        return mobileValidationError(error)
    }

    func mobileTerminalAliasValidationError(alias: MobileTerminalAliasUUID) -> V2CallResult? {
        guard let error = alias.validationError else {
            return nil
        }
        return mobileValidationError(error)
    }

    func mobileTerminalRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64
    ) -> MobileTerminalRenderGridFrame? {
        mobileTerminalRenderGridFrame(terminalPanel: terminalPanel, surfaceID: surfaceID, seq: seq, scrollbackLines: TerminalController.mobileReplayScrollbackLineBudget)
    }

    func mobileTerminalVTExportSnapshot(terminalPanel: TerminalPanel) -> String? {
        readTerminalTextFromVTExportForSnapshot(
            terminalPanel: terminalPanel,
            bindingAction: "write_active_file:copy,vt",
            lineLimit: nil,
            normalizeLineEndings: false
        )
    }

    func mobileTerminalApplyViewportReport(params: [String: Any], terminalPanel: TerminalPanel, sticky: Bool) {
        applyMobileViewportReport(params: params, terminalPanel: terminalPanel, sticky: sticky)
    }

    func mobileTerminalClearViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: reason)
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

    func mobileTerminalOrderedPanels(in workspace: Workspace) -> [any Panel] {
        orderedPanels(in: workspace)
    }

    var mobileTerminalInputQueueFullMessage: String { Self.terminalInputQueueFullMessage }
    var mobileTerminalSurfaceUnavailableMessage: String { Self.terminalSurfaceUnavailableMessage }
    var mobileTerminalProcessExitedMessage: String { Self.terminalProcessExitedMessage }
}
