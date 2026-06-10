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


// MARK: - Mobile terminal and viewport report methods
extension TerminalController {
    enum MobileTerminalAliasUUID {
        case missing
        case value(UUID)
        case invalid
        case conflict
    }

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard v2HasNonNullParam(params, key) else {
                continue
            }
            sawAlias = true
            guard let candidate = v2UUID(params, key) else {
                return .invalid
            }
            if let selected, selected != candidate {
                return .conflict
            }
            selected = selected ?? candidate
        }
        if let selected {
            return .value(selected)
        }
        return sawAlias ? .invalid : .missing
    }

    func mobileTerminalAliasValidationError(params: [String: Any]) -> V2CallResult? {
        switch mobileTerminalAliasUUID(params: params) {
        case .missing, .value:
            return nil
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }
    }

    func mobileWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard v2HasNonNullParam(params, "workspace_id"),
              v2UUID(params, "workspace_id") == nil else {
            return nil
        }
        return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
    }

    func clearAllMobileViewportReports(reason: String) {
        guard !mobileViewportReportsBySurfaceID.isEmpty ||
            !mobileViewportReportCleanupTimersBySurfaceID.isEmpty else {
            return
        }

        for timer in mobileViewportReportCleanupTimersBySurfaceID.values {
            timer.cancel()
        }
        let surfaceIDs = Array(mobileViewportReportsBySurfaceID.keys)
        mobileViewportReportsBySurfaceID.removeAll()
        mobileViewportReportCleanupTimersBySurfaceID.removeAll()

        for surfaceID in surfaceIDs {
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
        }
    }

    #if DEBUG
    func debugResetMobileViewportReportsForTesting() {
        clearAllMobileViewportReports(reason: "mobile.viewport.testReset")
    }

    func debugSetMobileViewportReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        var reports = mobileViewportReportsBySurfaceID[surfaceID] ?? [:]
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: updatedAt
        )
        mobileViewportReportsBySurfaceID[surfaceID] = reports
    }

    func debugMobileViewportReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        guard let reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            return nil
        }
        return Set(reports.keys)
    }
    #endif

    func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.terminalPanel(for: surfaceID)
    }

    func v2MobileWorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let createResult = v2WorkspaceCreate(params: createParams, tabManager: tabManager)
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which watches TabManager.$tabs directly. Don't fire here.
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }

    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return .err(code: "not_found", message: "Pane not found", data: nil)
        }
        guard let terminal = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            autoRefreshMetadata: false,
            preserveFocusWhenUnfocused: false
        ) else {
            return .err(code: "internal_error", message: "Failed to create terminal", data: nil)
        }
        // workspace.updated emit is handled by MobileWorkspaceListObserver.
        return v2MobileWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdTerminalID: terminal.id.uuidString
        )
    }

    func v2MobileTerminalReplay(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            #if DEBUG
            cmuxDebugLog("mobile.terminal.replay NOT_FOUND surface=\(v2RawString(params, "surface_id") ?? "nil")")
            #endif
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let state = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceId)
        let seq = state?.seq ?? 0
        let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            seq: seq
        )
        #if DEBUG
        cmuxDebugLog("mobile.terminal.replay surface=\(surfaceId.uuidString.prefix(8)) renderGrid=\(renderGrid != nil) seq=\(seq) hasState=\(state != nil)")
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "seq": seq,
        ]
        if let renderGrid,
           let renderGridObject = try? renderGrid.jsonObject() {
            payload["columns"] = renderGrid.columns
            payload["rows"] = renderGrid.rows
            payload["render_grid"] = renderGridObject
        } else {
            let snapshotData = readTerminalTextFromVTExportForSnapshot(
                terminalPanel: terminalPanel,
                bindingAction: "write_active_file:copy,vt",
                lineLimit: nil,
                normalizeLineEndings: false
            )?.data(using: .utf8) ?? Data()
            let data = state?.data ?? Data()
            if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalReplay") {
                let size = ghostty_surface_size(surface)
                payload["columns"] = max(Int(size.columns), 1)
                payload["rows"] = max(Int(size.rows), 1)
            }
            if !snapshotData.isEmpty {
                payload["snapshot_format"] = "ghostty.active.vt"
                payload["snapshot_data_b64"] = snapshotData.base64EncodedString()
            } else if !data.isEmpty {
                payload["data_b64"] = data.base64EncodedString()
            }
        }
        return .ok(payload)
    }

    /// Record (or clear) a paired device's reported terminal grid, recompute
    /// the smallest grid across all attached devices, cap this surface to it
    /// (drawing the macOS viewport border when the pane is larger), and return
    /// the resulting effective grid so the device can pin + letterbox its own
    /// render to match. This is the iOS/macOS half of the tmux-style shared
    /// resize: the smallest attached viewport wins and every device shows the
    /// same cols×rows with a clear border around the live area.
    func v2MobileTerminalViewport(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        if v2Bool(params, "clear") == true {
            if let clientID = v2String(params, "client_id") {
                clearMobileViewportReport(
                    surfaceID: terminalPanel.id,
                    clientID: clientID,
                    reason: "mobile.terminal.viewport.clear"
                )
            }
        } else {
            applyMobileViewportReport(params: params, terminalPanel: terminalPanel, sticky: true)
        }

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ]
        if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalViewport") {
            let size = ghostty_surface_size(surface)
            payload["columns"] = max(Int(size.columns), 1)
            payload["rows"] = max(Int(size.rows), 1)
        }
        return .ok(payload)
    }

    /// Forward a phone scroll gesture to the real surface so libghostty handles
    /// it per-mode (scrollback in the normal screen, mouse-wheel to the program
    /// in the alt screen). The producer already exports the live `vp_top`, so
    /// the resulting viewport mirrors back to the phone; nudge an emit since a
    /// pure scroll with no PTY output may not fire a render/tick on its own.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let deltaLines = (params["delta_lines"] as? NSNumber)?.doubleValue ?? 0
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        if deltaLines != 0 {
            terminalPanel.surface.mobileScroll(deltaLines: deltaLines, col: max(0, col), row: max(0, row))
            MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        }
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ])
    }

    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        terminalPanel.surface.mobileClick(col: max(0, col), row: max(0, row))
        MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ])
    }

    func v2MobileTerminalInput(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        #if DEBUG
        let sendStart = ProcessInfo.processInfo.systemUptime
        #endif
        let sendResult = terminalPanel.surface.sendInputResult(text)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalInput")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
        cmuxDebugLog(
            "mobile.terminal.input workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) queued=\(sendResult == .queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
        )
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ]
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    /// Handle `terminal.paste_image`: a paired client (the iOS app) forwards an
    /// image it pasted as base64 bytes. We materialize it to a temp file on the
    /// Mac and inject the shell-escaped path as terminal input, exactly the way a
    /// local clipboard-image paste does, so the running TUI (e.g. Claude Code)
    /// attaches the image from the path.
    func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {
        guard let base64 = v2RawString(params, "image_base64"),
              let imageData = Data(base64Encoded: base64), !imageData.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid image_base64", data: nil)
        }
        let format = v2RawString(params, "image_format") ?? "png"
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        guard let escapedPath = GhosttyPasteboardHelper.saveImageData(imageData, fileExtension: format) else {
            return .err(code: "invalid_params", message: "Image payload was empty or exceeded the size limit", data: nil)
        }

        let sendResult = terminalPanel.surface.sendInputResult(escapedPath)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPasteImage")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste_image workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) bytes=\(imageData.count) format=\(format)"
        )
        #endif
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ])
    }

    private func applyMobileViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool = false
    ) {
        guard let clientID = v2String(params, "client_id"),
              let rawColumns = v2Int(params, "viewport_columns"),
              let rawRows = v2Int(params, "viewport_rows") else {
            return
        }

        let columns = min(max(rawColumns, 20), 300)
        let rows = min(max(rawRows, 5), 120)
        let now = Date()
        var reports = mobileViewportReportsBySurfaceID[terminalPanel.id] ?? [:]
        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: now,
            sticky: sticky
        )
        mobileViewportReportsBySurfaceID[terminalPanel.id] = reports
        scheduleMobileViewportReportCleanup(surfaceID: terminalPanel.id, reports: reports)

        guard let minColumns = reports.values.map(\.columns).min(),
              let minRows = reports.values.map(\.rows).min() else {
            return
        }
        terminalPanel.surface.applyMobileViewportLimit(
            columns: minColumns,
            rows: minRows,
            reason: "mobile.terminal.input"
        )
    }

    /// Remove a single client's viewport report for a surface (dedicated
    /// `mobile.terminal.viewport` clear, or a disconnect), then recompute the
    /// remaining min and re-apply or clear the surface's viewport limit so the
    /// macOS border reflects only the devices still attached.
    private func clearMobileViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID],
              reports.removeValue(forKey: clientID) != nil else {
            return
        }
        if reports.isEmpty {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }
        mobileViewportReportsBySurfaceID[surfaceID] = reports
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
    }

    /// Drop every viewport report owned by the given client IDs across all
    /// surfaces. Called when a mobile connection closes so a disconnected
    /// device stops pinning the grid even though it never sent an explicit
    /// clear. Sticky reports rely on this signal instead of the TTL.
    func clearMobileViewportReports(clientIDs: Set<String>, reason: String) {
        guard !clientIDs.isEmpty else { return }
        for surfaceID in Array(mobileViewportReportsBySurfaceID.keys) {
            for clientID in clientIDs {
                clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: reason)
            }
        }
    }

    private func scheduleMobileViewportReportCleanup(
        surfaceID: UUID,
        reports: [String: MobileViewportReport]
    ) {
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
        // Sticky reports live for the connection lifetime, so they never drive
        // a TTL timer; only non-sticky (input-piggyback) reports expire.
        guard let nextExpiry = reports.values
            .filter({ !$0.sticky })
            .map({ $0.updatedAt.addingTimeInterval(Self.mobileViewportReportTTL) })
            .min() else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let millisecondsUntilExpiry = max(1, Int((nextExpiry.timeIntervalSinceNow + 1) * 1000))
        timer.schedule(deadline: .now() + .milliseconds(millisecondsUntilExpiry))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pruneMobileViewportReports(surfaceID: surfaceID, reason: "mobile.viewport.reportsExpired")
            }
        }
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = timer
        timer.resume()
    }

    private func pruneMobileViewportReports(surfaceID: UUID, reason: String) {
        let now = Date()
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }

        guard !reports.isEmpty else {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }

        mobileViewportReportsBySurfaceID[surfaceID] = reports
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
    }

    func mobileResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID?)? {
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return nil
        }

        let requestedSurfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id")

        let surfaceId: UUID?
        if let requestedSurfaceId {
            guard workspace.panels[requestedSurfaceId] != nil else {
                return nil
            }
            surfaceId = requestedSurfaceId
        } else if requireTerminal {
            surfaceId = workspace.focusedTerminalPanel?.id
                ?? mobileTerminalPanels(in: workspace).first?.id
        } else {
            surfaceId = nil
        }

        // A session-restored / never-foregrounded terminal has its libghostty
        // surface created lazily — today only on the first keystroke (via the
        // input path's `requestBackgroundSurfaceStartIfNeeded`). The mobile
        // render-grid producer only reads a *live* surface, so such a terminal
        // shows blank on the phone until the user types. When a mobile client
        // resolves a terminal to read or drive, materialize the surface
        // headlessly so attaching alone loads it. Idempotent and a no-op once
        // the surface exists.
        if requireTerminal,
           let surfaceId,
           let panel = workspace.terminalPanel(for: surfaceId) {
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
        }

        return (tabManager, workspace, surfaceId)
    }

    func mobileTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        // Use the workspace's spatial (left-to-right, top-to-bottom) panel order
        // so the phone's terminal dropdown matches the on-screen bonsplit layout,
        // rather than focused-first/UUID order. `is_focused` in the payload still
        // tells the phone which terminal is active.
        orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }
    }

    func mobileNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

}
