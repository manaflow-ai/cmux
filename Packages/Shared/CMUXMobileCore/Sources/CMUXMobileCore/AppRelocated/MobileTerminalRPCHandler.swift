import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CmuxPanes
import CmuxTerminal
import Foundation
import GhosttyKit

/// Owns the mobile terminal-IO RPC dispatch: the Mac side of the iOS terminal
/// data plane (`mobile.terminal.*`) plus the mobile `workspace.create` echo.
///
/// Creates terminals and workspaces, replays a terminal's live grid (or a VT
/// snapshot fallback), records device viewport reports for the tmux-style shared
/// resize, forwards phone scroll/mouse gestures to libghostty, and injects text /
/// pasted blocks / pasted images into the resolved surface. It reaches the
/// terminal data plane (param/UUID coercion, tab-manager / workspace / window
/// resolution, the shared workspace-create and workspace-list bodies, the
/// app-coupled render-grid / viewport / VT-export machinery, and the localized
/// terminal error messages) only through the ``MobileTerminalRPCHost`` seam.
/// Live ``Workspace`` / ``TerminalPanel`` members and the process-wide
/// ``MobileTerminalByteTee`` / ``MobileTerminalRenderObserver`` it touches
/// directly, exactly as the former methods on the data-plane god object did.
/// This type replaces that block of `v2MobileTerminal*` / `v2MobileWorkspaceCreate`
/// methods: the same logic, relocated off the god object into a
/// constructor-injected owner.
///
/// `@MainActor` because every body it owns reads or mutates main-actor terminal /
/// workspace state and the seam it drives is `@MainActor`.
@MainActor
final class MobileTerminalRPCHandler {
    private let host: any MobileTerminalRPCHost

    /// Held metadata-detection matcher (built over the built-in agent catalog
    /// once, reused per call) for the Claude-aware submit-key upgrade in the
    /// paste path. Mirrors the detector the chat handler holds.
    private let agentMetadataDetector = AgentMetadataDetector()

    /// - Parameter host: the terminal data-plane seam the terminal handlers drive
    ///   (param coercion, tab-manager / workspace / window resolution, shared
    ///   create / list bodies, the render-grid / viewport / VT-export machinery,
    ///   and the localized terminal error messages).
    init(host: any MobileTerminalRPCHost) {
        self.host = host
    }

    // MARK: - Dispatch

    /// Routes one mobile terminal-IO method to its handler. The mobile
    /// data-plane RPC switch in `mobileHostHandleRPC` forwards each
    /// `mobile.terminal.*` / mobile `workspace.create` arm here, keeping the
    /// god-file dispatch flat.
    func dispatch(method: String, params: [String: Any]) -> TerminalController.V2CallResult {
        switch method {
        case "workspace.create":
            return workspaceCreate(params: params)
        case "mobile.terminal.create", "terminal.create":
            return terminalCreate(params: params)
        case "mobile.terminal.input", "terminal.input":
            return terminalInput(params: params)
        case "mobile.terminal.paste", "terminal.paste":
            return terminalPaste(params: params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            return terminalPasteImage(params: params)
        case "mobile.terminal.replay", "terminal.replay":
            return terminalReplay(params: params)
        case "mobile.terminal.viewport", "terminal.viewport":
            return terminalViewport(params: params)
        case "mobile.terminal.scroll", "terminal.scroll":
            return terminalScroll(params: params)
        case "mobile.terminal.mouse", "terminal.mouse":
            return terminalMouse(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }

    // MARK: - Param helpers (owned)

    /// Classifies the `surface_id` / `terminal_id` / `tab_id` terminal alias
    /// triple exactly as the legacy body did (missing / value / invalid /
    /// conflict). Owned here; ``TerminalController`` forwards to it for the
    /// attach-ticket and workspace-list callers that still resolve the alias.
    func aliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard host.mobileTerminalHasNonNullParam(params, key) else {
                continue
            }
            sawAlias = true
            guard let candidate = host.mobileTerminalUUID(params, key) else {
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

    // MARK: - Workspace / terminal creation

    func workspaceCreate(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let tabManager = host.mobileTerminalResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let createResult = host.mobileTerminalWorkspaceCreate(params: createParams, tabManager: tabManager)
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which observes the workspace list (`workspaces.tabs`) directly.
            // Don't fire here.
            return host.mobileTerminalWorkspaceList(
                params: createParams,
                tabManager: tabManager,
                createdWorkspaceID: createdWorkspaceID,
                createdTerminalID: nil
            )
        case .err:
            return createResult
        }
    }

    func terminalCreate(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let tabManager = host.mobileTerminalResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspace = host.mobileTerminalResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return .err(code: "not_found", message: "Pane not found", data: nil)
        }
        guard let terminal = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            autoRefreshMetadata: false,
            preserveFocusWhenUnfocused: false, inheritWorkingDirectoryFallback: true
        ) else {
            return .err(code: "internal_error", message: "Failed to create terminal", data: nil)
        }
        // workspace.updated emit is handled by MobileWorkspaceListObserver.
        return host.mobileTerminalWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdWorkspaceID: nil,
            createdTerminalID: terminal.id.uuidString
        )
    }

    // MARK: - Replay / viewport / scroll / mouse

    func terminalReplay(params: [String: Any]) -> TerminalController.V2CallResult {
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            #if DEBUG
            cmuxDebugLog("mobile.terminal.replay NOT_FOUND surface=\(host.mobileTerminalRawStringParam(params, "surface_id") ?? "nil")")
            #endif
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let state = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceId)
        let seq = state?.seq ?? 0
        let renderGrid = host.mobileTerminalRenderGridFrame(
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
            let snapshotData = host.mobileTerminalVTExportSnapshot(terminalPanel: terminalPanel)?.data(using: .utf8) ?? Data()
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
    func terminalViewport(params: [String: Any]) -> TerminalController.V2CallResult {
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        if host.mobileTerminalBoolParam(params, "clear") == true {
            if let clientID = host.mobileTerminalStringParam(params, "client_id") {
                host.mobileTerminalClearViewportReport(
                    surfaceID: terminalPanel.id,
                    clientID: clientID,
                    reason: "mobile.terminal.viewport.clear"
                )
            }
        } else {
            host.mobileTerminalApplyViewportReport(params: params, terminalPanel: terminalPanel, sticky: true)
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
    func terminalScroll(params: [String: Any]) -> TerminalController.V2CallResult {
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
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
        return .ok(host.mobileTerminalScrollPayload(
            workspaceID: resolved.workspace.id,
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            params: params
        ))
    }

    func terminalMouse(params: [String: Any]) -> TerminalController.V2CallResult {
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
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

    // MARK: - Input / paste

    func terminalInput(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let text = host.mobileTerminalRawStringParam(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        host.mobileTerminalApplyViewportReport(params: params, terminalPanel: terminalPanel, sticky: false)

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
            return .err(code: "input_queue_full", message: host.mobileTerminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: host.mobileTerminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: host.mobileTerminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
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
    func terminalPasteImage(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let base64 = host.mobileTerminalRawStringParam(params, "image_base64"),
              let imageData = Data(base64Encoded: base64), !imageData.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid image_base64", data: nil)
        }
        let format = host.mobileTerminalRawStringParam(params, "image_format") ?? "png"
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        host.mobileTerminalApplyViewportReport(params: params, terminalPanel: terminalPanel, sticky: false)

        guard let escapedPath = GhosttyApp.terminalPasteboard.saveImageData(imageData, fileExtension: format) else {
            return .err(code: "invalid_params", message: "Image payload was empty or exceeded the size limit", data: nil)
        }

        let sendResult = terminalPanel.surface.sendInputResult(escapedPath)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPasteImage")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: host.mobileTerminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: host.mobileTerminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: host.mobileTerminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
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

    /// Deliver a composed block from the mobile composer as a bracketed paste
    /// followed by an optional single submit key.
    ///
    /// This mirrors the macOS TextBox composer dispatch
    /// (`[.pasteText(payload), .namedKey(submitKey)]`): the text goes through
    /// `sendText` (libghostty `ghostty_surface_text`), which bracketed-pastes it
    /// (`ESC[200~ … ESC[201~` when DECSET 2004 is active) so the agent's line
    /// editor inserts the whole, possibly multi-line, block as literal text
    /// instead of treating every interior newline as a submit. A single named
    /// submit key then commits it once. The `terminal.input` path is wrong for a
    /// composed block: `parsedSocketInputEvents` rewrites every `\n`/`\r` to a
    /// raw CR, so an N-line message fragments into N submissions.
    ///
    /// `submit_key` is optional: `return`/`enter` (default) or `ctrl+enter`
    /// submit; `none` pastes without submitting so the composer can keep editing.
    func terminalPaste(params: [String: Any]) -> TerminalController.V2CallResult {
        guard let text = host.mobileTerminalRawStringParam(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        // Resolve the optional submit key up front so an unsupported value fails
        // before any text is pasted (no partial application). The phone sends
        // `return` as the default submit *intent*; the agent-aware upgrade to
        // `ctrl+enter` happens below once the surface (and its agent context) is
        // resolved, because only the Mac knows which agent is running.
        let submitKeyRaw = (host.mobileTerminalStringParam(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(code: "invalid_params", message: "Unsupported submit_key", data: ["submit_key": submitKeyRaw])
        }
        if let error = host.mobileTerminalWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = host.mobileTerminalAliasValidationError(alias: aliasUUID(params: params)) {
            return error
        }
        guard let resolved = resolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        // Mirror the macOS TextBox composer's submit-key selection
        // (`TextBoxInput.dispatchEvents`): Claude Code needs `ctrl+enter` to
        // submit a multi-line block, while plain `return` submits a newline mid
        // prompt. The phone cannot know the running agent, so it always asks for
        // `return`; upgrade that intent here when the surface is Claude and the
        // composed text spans multiple lines. Explicit `ctrl+enter`/`none` from
        // the client are honored as-is.
        if submitKeyWasReturnIntent,
           text.contains("\n") || text.contains("\r"),
           agentMetadataDetector.isClaudeCode(
               context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
           ) {
            submitKeyName = "ctrl+enter"
        }

        host.mobileTerminalApplyViewportReport(params: params, terminalPanel: terminalPanel, sticky: false)

        // Send through the TerminalPanel explicit-input wrappers (not the raw
        // surface): they run `resumeForExplicitInputIfNeeded()` first, waking a
        // hibernated agent terminal the same way local typing does, so a mobile
        // composer submit cannot write into a cold surface.
        guard terminalPanel.sendText(text) else {
            return .err(code: "surface_unavailable", message: host.mobileTerminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        }

        // The paste text is already accepted by the surface above. From here on a
        // submit-key failure must NOT surface as an RPC error: the client treats
        // any error as "nothing was sent" and keeps the composer draft, so a
        // retry would paste the whole block a second time. Report partial
        // success instead — `submitted: false` plus `submit_error` — so the
        // client clears the draft (the text is sitting at the prompt) and can
        // tell the user the submit keypress is still needed.
        var submitted = false
        var submitError: String?
        if let submitKeyName {
            let keyResult = terminalPanel.sendNamedKeyResult(submitKeyName)
            if keyResult.accepted {
                submitted = true
            } else {
                switch keyResult {
                case .inputQueueFull:
                    submitError = "input_queue_full"
                case .surfaceUnavailable:
                    submitError = "surface_unavailable"
                case .processExited:
                    submitError = "process_exited"
                case .unknownKey, .sent, .queued:
                    // .sent / .queued are accepted results and unreachable in this
                    // else-branch; grouped here only to keep the switch exhaustive.
                    submitError = "unknown_key"
                }
            }
        }

        terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPaste")

        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) chars=\(text.count) submitted=\(submitted ? 1 : 0)"
        )
        #endif

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "submitted": submitted,
        ]
        if let submitError {
            payload["submit_error"] = submitError
        }
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    // MARK: - Resolution (owned)

    /// Resolves a workspace and (optionally) its target terminal surface from
    /// RPC params, materializing a lazily-created surface when `requireTerminal`
    /// is set. Owned here; ``TerminalController`` forwards to it for the
    /// attach-ticket and chat callers that share this resolution.
    func resolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID?)? {
        guard let tabManager = host.mobileTerminalResolveTabManager(params: params),
              let workspace = host.mobileTerminalResolveWorkspace(params: params, tabManager: tabManager) else {
            return nil
        }

        let requestedSurfaceId = host.mobileTerminalUUID(params, "surface_id")
            ?? host.mobileTerminalUUID(params, "terminal_id")
            ?? host.mobileTerminalUUID(params, "tab_id")

        let surfaceId: UUID?
        if let requestedSurfaceId {
            guard workspace.panels[requestedSurfaceId] != nil else {
                return nil
            }
            surfaceId = requestedSurfaceId
        } else if requireTerminal {
            surfaceId = workspace.focusedTerminalPanel?.id
                ?? terminalPanels(in: workspace).first?.id
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

    /// The terminal panels of `workspace` in display order. Owned here;
    /// ``TerminalController`` forwards to it for the workspace-list serializer.
    func terminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        // Use the workspace's spatial (left-to-right, top-to-bottom) panel order
        // so the phone's terminal dropdown matches the on-screen bonsplit layout,
        // rather than focused-first/UUID order. `is_focused` in the payload still
        // tells the phone which terminal is active.
        host.mobileTerminalOrderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }
    }
}
