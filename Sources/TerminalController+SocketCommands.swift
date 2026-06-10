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


// MARK: - V1 socket command dispatch
extension TerminalController {
#if DEBUG
    struct SocketCommandDebugInfo {
        let protocolName: String
        let commandKey: String
    }

    nonisolated static func socketCommandDebugLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[socketCommandDebugLogEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    nonisolated static func socketCommandDebugInfo(_ command: String) -> SocketCommandDebugInfo {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let method = dict["method"] as? String else {
            let commandKey = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            return SocketCommandDebugInfo(protocolName: "v1", commandKey: sanitizedSocketDebugToken(commandKey))
        }
        return SocketCommandDebugInfo(protocolName: "v2", commandKey: sanitizedSocketDebugToken(method))
    }

    private nonisolated static func sanitizedSocketDebugToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    private nonisolated static func socketCommandDebugStatus(response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return "error"
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if topLevelJSONResponseStatus(in: prefix) == "error" {
                return "error"
            }
        }
        return "ok"
    }

    private nonisolated static func topLevelJSONResponseStatus(in text: Substring) -> String? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "error" {
                return "error"
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return "error"
                }
                if text[index...].hasPrefix("true") {
                    return "ok"
                }
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func scanJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private nonisolated static func skipJSONValue(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanJSONString(in: text, index: &index) != nil
        case "{", "[":
            return skipJSONContainer(in: text, index: &index)
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private nonisolated static func skipJSONContainer(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }

    nonisolated static func debugLogSocketCommandEndIfNeeded(
        debugInfo: SocketCommandDebugInfo,
        startedAt: UInt64,
        response: String,
        loggingEnabled: Bool
    ) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let status = socketCommandDebugStatus(response: response)
        guard loggingEnabled || elapsedMs >= socketCommandSlowThresholdMs || status != "ok" else {
            return
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        debugLogSocketCommand(
            "socket.command.end proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey) status=\(status) ms=\(elapsedText) bytes=\(response.utf8.count)"
        )
    }

    nonisolated static func debugLogSocketCommand(_ message: @autoclosure () -> String) {
        cmuxDebugLog(message())
    }
#endif

    nonisolated func processCommandUsingSocketExecutionPolicy(_ command: String) -> String? {
        if Thread.isMainThread,
           let request = parseV2SocketRequest(command),
           Self.executionPolicy(forV2Method: request.method) == .socketWorker(mainThreadCallable: false) {
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: "\(request.method) must run off the main thread"
            )
        }

        let socketWorkerResult = socketWorkerV2ResponseIfHandled(for: command)
        if socketWorkerResult.handled {
            guard let response = socketWorkerResult.response else {
                return nil
            }
            return response
        }

        if command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ping" {
            return withSocketCommandPolicy(commandKey: "ping", isV2: false) {
                "PONG"
            }
        }

        return v2MainSync {
            self.processCommand(command)
        }
    }

    /// Public entry point mirroring the socket's `processCommand` path so
    /// in-process callers (e.g. the Feed coordinator's `feed.jump` focus
    /// request) can reuse the full V1/V2 dispatcher without duplicating
    /// its auth/policy wrappers.
    nonisolated func handleSocketLine(_ line: String) -> String {
        return processCommandUsingSocketExecutionPolicy(line) ?? ""
    }

    func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        let policyParams = cmd == "right_sidebar" ? ["args": args] : [:]
        return withSocketCommandPolicy(commandKey: cmd, isV2: false, params: policyParams) {
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace(args)

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "notify_target_async":
            return notifyTargetQueued(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications(args)

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        case "set_status":
            return setStatus(args)

        case "report_meta":
            return reportMeta(args)

        case "report_meta_block":
            return reportMetaBlock(args)

        case "clear_status":
            return clearStatus(args)

        case "set_agent_pid":
            return setAgentPID(args)

        case "set_agent_lifecycle":
            return setAgentLifecycle(args)

        case "agent_hibernation":
            return agentHibernation(args)

        case "clear_agent_pid":
            return clearAgentPID(args)

        case "clear_meta":
            return clearMeta(args)

        case "clear_meta_block":
            return clearMetaBlock(args)

        case "list_status":
            return listStatus(args)

        case "list_meta":
            return listMeta(args)

        case "list_meta_blocks":
            return listMetaBlocks(args)

        case "log":
            return appendLog(args)

        case "clear_log":
            return clearLog(args)

        case "list_log":
            return listLog(args)

        case "set_progress":
            return setProgress(args)

        case "clear_progress":
            return clearProgress(args)

        case "report_git_branch":
            return reportGitBranch(args)

        case "clear_git_branch":
            return clearGitBranch(args)

        case "report_pr":
            return reportPullRequest(args)

        case "report_review":
            return reportPullRequest(args)

        case "clear_pr":
            return clearPullRequest(args)

        case "report_ports":
            return reportPorts(args)

        case "clear_ports":
            return clearPorts(args)

        case "report_tty":
            return reportTTY(args)

        case "ports_kick":
            return portsKick(args)

        case "report_shell_state":
            return reportShellState(args)

        case "report_pr_action":
            return reportPullRequestAction(args)

        case "report_pwd":
            return reportPwd(args)

        case "sidebar_state":
            return sidebarState(args)

        case "reset_sidebar":
            return resetSidebar(args)

        case "right_sidebar":
            return rightSidebar(args)

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "send_workspace":
            return sendInputToWorkspace(args)

        case "set_shortcut":
            return setShortcut(args)

        case "simulate_shortcut":
            return simulateShortcut(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)

        case "activate_app":
            return activateApp()

        case "is_terminal_focused":
            return isTerminalFocused(args)

        case "read_terminal_text":
            return readTerminalText(args)

        case "render_stats":
            return renderStats(args)

        case "layout_debug":
            return layoutDebug()

        case "bonsplit_underflow_count":
            return bonsplitUnderflowCount()

        case "reset_bonsplit_underflow_count":
            return resetBonsplitUnderflowCount()

        case "empty_panel_count":
            return emptyPanelCount()

        case "reset_empty_panel_count":
            return resetEmptyPanelCount()

        case "focus_notification":
            return focusFromNotification(args)

        case "debug_right_sidebar_focus":
            return debugRightSidebarFocus(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()

        case "panel_snapshot":
            return panelSnapshot(args)

        case "panel_snapshot_reset":
            return panelSnapshotReset(args)

        case "screenshot":
            return captureScreenshot(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands
        case "open_browser":
            return openBrowser(args)

        case "navigate":
            return navigateBrowser(args)

        case "browser_back":
            return browserBack(args)

        case "browser_forward":
            return browserForward(args)

        case "browser_reload":
            return browserReload(args)

        case "get_url":
            return getUrl(args)

        case "focus_webview":
            return focusWebView(args)

        case "is_webview_focused":
            return isWebViewFocused(args)

        case "list_panes":
            return listPanes()

        case "list_pane_surfaces":
            return listPaneSurfaces(args)

	        case "focus_pane":
	            return focusPane(args)

	        case "focus_surface_by_panel":
	            return focusSurfaceByPanel(args)

	        case "drag_surface_to_split":
	            return dragSurfaceToSplit(args)

	        case "new_pane":
	            return newPane(args)

        case "new_surface":
            return newSurface(args)

        case "close_surface":
            return closeSurface(args)

        case "reload_config":
            return reloadConfig(args)

        case "refresh_surfaces":
            return refreshSurfaces()

            case "surface_health":
                return surfaceHealth(args)

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    // MARK: - V2 JSON Socket Protocol

    private func helpText() -> String {
        var text = """
        Hierarchy: Workspace (sidebar tab) > Pane (split region) > Surface (nested tab) > Panel (terminal/browser)

        Available commands:
          ping                        - Check if server is running
          list_workspaces             - List all workspaces with IDs
          new_workspace               - Create a new workspace
          select_workspace <id|index> - Select workspace by ID or index (0-based)
          current_workspace           - Get current workspace ID
          close_workspace <id>        - Close workspace by ID

        Split & surface commands:
          new_split <direction> [panel]   - Split panel (left/right/up/down)
          drag_surface_to_split <id|idx> <direction> - Move surface into a new split (drag-to-edge)
          new_pane [--type=terminal|browser] [--direction=left|right|up|down] [--url=...]
          new_surface [--type=terminal|browser] [--pane=<pane-id|index>] [--url=...]
          list_surfaces [workspace]       - List surfaces for workspace (current if omitted)
          list_panes                      - List all panes with IDs
          list_pane_surfaces [--pane=<pane-id|index>] - List surfaces in pane
          focus_surface <id|idx>          - Focus surface by ID or index
          focus_pane <pane-id|index>      - Focus a pane
          focus_surface_by_panel <panel_id> - Focus surface by panel ID
          close_surface [id|idx]          - Close surface (collapse split)
          reload_config                   - Reload Ghostty config, cmux settings, and refresh terminals
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key (ctrl-c, ctrl-d, ctrl-f, enter, tab, escape)
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          notify_target_async <workspace_uuid> <surface_uuid> <payload> - Queue notification by workspace+surface
          list_notifications              - List all notifications
          clear_notifications [--tab=X] [--panel=ID] - Clear notifications (all, per-tab, or per-panel)
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set a status entry
          set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=X] [--panel=ID] - Report coding-agent lifecycle for hibernation
          agent_hibernation <on|off> - Enable or disable Agent Hibernation
          report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set sidebar metadata entry
          report_meta_block <key> [--priority=N] [--tab=X] -- <markdown> - Set freeform sidebar markdown block
          clear_status <key> [--tab=X] - Remove a status entry
          clear_meta <key> [--tab=X] - Remove sidebar metadata entry
          clear_meta_block <key> [--tab=X] - Remove sidebar markdown block
          list_status [--tab=X]   - List all status entries
          list_meta [--tab=X]     - List sidebar metadata entries
          list_meta_blocks [--tab=X] - List sidebar markdown blocks
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty|clean|unknown] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y] - Report pull request / review item
          report_review <number> <url> [--label=MR] [--state=open|merged|closed] [--tab=X] [--panel=Y] - Alias for provider-specific review item
          clear_pr [--tab=X] [--panel=Y] - Clear pull request
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] [--reason=command|refresh] - Request batched port scan for panel
          report_shell_state <prompt|running> [--tab=X] [--panel=Y] - Report whether the shell is idle at a prompt or running a command
          report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y] - Hint that a PR-affecting command completed in the panel
          report_pwd <path> [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
          right_sidebar <toggle|show|hide|focus|set|mode> [mode] [--tab=X] [--window=Y] [--no-focus] - Control right sidebar visibility, mode, and focus
          sidebar_state [--tab=X] - Dump sidebar metadata
          reset_sidebar [--tab=X] - Clear sidebar metadata

        Browser commands:
          open_browser [url]              - Create browser panel with optional URL
          navigate <panel_id> <url>       - Navigate browser to URL
          browser_back <panel_id>         - Go back in browser history
          browser_forward <panel_id>      - Go forward in browser history
          browser_reload <panel_id>       - Reload browser page
          get_url <panel_id>              - Get current URL of browser panel
          focus_webview <panel_id>        - Move keyboard focus into the WKWebView (for tests)
          is_webview_focused <panel_id>   - Return true/false if WKWebView is first responder

          help                            - Show this help
        """
#if DEBUG
        text += """

          focus_notification <workspace|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>            - Read flash count for a panel
          reset_flash_counts              - Reset flash counters
          screenshot [label]              - Capture window screenshot
          set_shortcut <name> <combo|clear> - Set a keyboard shortcut (test-only)
          simulate_shortcut <combo>       - Simulate a keyDown shortcut (test-only)
          simulate_type <text>            - Insert text into the current first responder (test-only)
          simulate_file_drop <id|idx> <path[|path...]> - Simulate dropping file path(s) on terminal (test-only)
          seed_drag_pasteboard_fileurl    - Seed NSDrag pasteboard with public.file-url (test-only)
          seed_drag_pasteboard_tabtransfer - Seed NSDrag pasteboard with tab transfer type (test-only)
          seed_drag_pasteboard_sidebar_reorder - Seed NSDrag pasteboard with sidebar reorder type (test-only)
          seed_drag_pasteboard_types <types> - Seed NSDrag pasteboard with comma/space-separated types (fileurl, tabtransfer, sidebarreorder, or raw UTI)
          clear_drag_pasteboard           - Clear NSDrag pasteboard (test-only)
          drop_hit_test <x 0-1> <y 0-1> - Hit-test file-drop overlay at normalised coords (test-only)
          drag_hit_chain <x 0-1> <y 0-1> - Return hit-view chain at normalised coords (test-only)
          overlay_hit_gate <event|none> - Return true/false if file-drop overlay would capture hit-testing for event type (test-only)
          overlay_drop_gate [external|local] - Return true/false if file-drop overlay would capture drag destination routing (test-only)
          portal_hit_gate <event|none> - Return true/false if terminal portal should pass hit-testing to SwiftUI drag targets (test-only)
          sidebar_overlay_gate [active|inactive] - Return true/false if sidebar outside-drop overlay would capture (test-only)
          terminal_drop_overlay_probe [deferred|direct] - Trigger focused terminal drop-overlay show path and report animation counts (test-only)
          activate_app                    - Bring app + main window to front (test-only)
          send_workspace <workspace_id> <text> - Send text to a workspace's selected terminal (test-only)
          is_terminal_focused <id|idx>    - Return true/false if terminal surface is first responder (test-only)
          read_terminal_text [id|idx]     - Read visible terminal text (base64, test-only)
          render_stats [id|idx]           - Read terminal render stats (draw counters, test-only)
          layout_debug                    - Dump bonsplit layout + selected panel bounds (test-only)
          bonsplit_underflow_count        - Count bonsplit arranged-subview underflow events (test-only)
          reset_bonsplit_underflow_count  - Reset bonsplit underflow counter (test-only)
          empty_panel_count               - Count EmptyPanelView appearances (test-only)
          reset_empty_panel_count         - Reset EmptyPanelView appearance count (test-only)
        """
#endif
        return text
    }

}
