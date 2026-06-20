import Bonsplit
import CmuxControlSocket
import Foundation

/// The v1 line-protocol surface/send/notify/help witnesses and the v1 string
/// bodies they run (`listSurfaces`, `focusSurface`, `sendInput`, `sendKey`,
/// `sendInputToSurface`, `sendKeyToSurface`, `sendInputToWorkspace`,
/// `readScreenText`, `notifyCurrent`, `notifySurface`, `notifyTarget`,
/// `notifyTargetQueued`, `listNotifications`, `clearNotifications`, `helpText`).
///
/// These bodies are irreducibly app-coupled — they read live `TabManager` /
/// `Workspace` / `TerminalPanel` state through `v2MainSync`, deliver through
/// `TerminalMutationBus` / `TerminalNotificationStore`, and the help text is
/// frozen app-resident copy with a DEBUG/release split — so they stay in the app
/// target rather than the `CmuxControlSocket` package. They were drained out of
/// the `TerminalController.swift` god file into this conformance file (the v1
/// `processCommand` switch already routes them through
/// ``ControlCommandCoordinator/handleSurfaceSendNotifyV1(command:args:)``, whose
/// only callers of these bodies are the witnesses below). Each body is the
/// verbatim former god-file body, so the wire output stays byte-identical. The
/// shared resolvers they call (`resolveTab`, `resolveSurfaceId`, `orderedPanels`,
/// `resolveTerminalPanel`, the panel-level `readTerminalTextBase64`) stay in
/// `TerminalController.swift` because non-relocated callers also use them. The
/// matching ``ControlAppFocusContext`` witnesses live in
/// `TerminalController+ControlAppFocusContext.swift`.
extension TerminalController {
    func controlSurfaceListV1(tabArg: String) -> String { listSurfaces(tabArg) }

    func controlSurfaceFocusV1(arg: String) -> String { focusSurface(arg) }

    func controlSurfaceSendInputV1(text: String) -> String { sendInput(text) }

    func controlSurfaceSendKeyV1(keyName: String) -> String { sendKey(keyName) }

    func controlSurfaceSendInputToSurfaceV1(args: String) -> String { sendInputToSurface(args) }

    func controlSurfaceSendKeyToSurfaceV1(args: String) -> String { sendKeyToSurface(args) }

    #if DEBUG
    func controlSurfaceSendInputToWorkspaceV1(args: String) -> String { sendInputToWorkspace(args) }
    #endif

    func controlSurfaceReadScreenV1(args: String) -> String { readScreenText(args) }

    func controlNotifyCurrentV1(args: String) -> String { notifyCurrent(args) }

    func controlNotifySurfaceV1(args: String) -> String { notifySurface(args) }

    func controlNotifyTargetV1(args: String) -> String { notifyTarget(args) }

    func controlNotifyTargetQueuedV1(args: String) -> String { notifyTargetQueued(args) }

    func controlNotificationsListV1() -> String { listNotifications() }

    func controlNotificationsClearV1(args: String) -> String { clearNotifications(args) }

    func controlHelpTextV1() -> String { helpText() }

    private struct ReadScreenOptions {
        let surfaceArg: String
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    private struct ReadScreenParseError: Error {
        let message: String
    }

    private func parseReadScreenArgs(_ args: String) -> Result<ReadScreenOptions, ReadScreenParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ReadScreenParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ReadScreenParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }

    // `internal` (not `private`): the relocated `readTerminalText` witness in
    // `TerminalController+ControlDebugContext.swift` calls this surface-arg
    // reader, so it must be visible across the conformance files.
    func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            result = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        return result
    }

    func readScreenText(_ args: String) -> String {
        let options: ReadScreenOptions
        switch parseReadScreenArgs(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            return error.message
        }

        let response = readTerminalTextBase64(
            surfaceArg: options.surfaceArg,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        )
        guard response.hasPrefix("OK ") else { return response }

        let payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            return ""
        }

        guard let data = Data(base64Encoded: payload) else {
            return "ERROR: Failed to decode terminal text"
        }
        return String(decoding: data, as: UTF8.self)
    }

    func helpText() -> String {
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

    func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let focusedId = tab.focusedPanelId
            let lines = panels.enumerated().map { index, panel in
                let selected = panel.id == focusedId ? "*" : " "
                return "\(selected) \(index): \(panel.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let index = Int(trimmed), index >= 0 {
                let panels = orderedPanels(in: tab)
                guard index < panels.count else { return }
                guard tab.surfaceIdFromPanelId(panels[index].id) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: panels[index].id)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    func notifyCurrent(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId else {
                result = "ERROR: No tab selected"
                return
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            let (title, subtitle, body) = parseNotificationPayload(args)
            deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func notifySurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let surfaceArg = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: surfaceArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func notifyTarget(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let tabArg = parts[0]
        let panelArg = parts[1]
        let payload = parts.count > 2 ? parts[2] : ""
        let (title, subtitle, body) = parseNotificationPayload(payload)

        if let workspaceId = UUID(uuidString: tabArg),
           let panelId = UUID(uuidString: panelArg) {
            var result = "OK"
            v2MainSync {
                guard let tab = self.tabForSidebarMutation(id: workspaceId) else {
                    result = "ERROR: Tab not found"
                    return
                }
                guard tab.panels[panelId] != nil else {
                    result = "ERROR: Panel not found"
                    return
                }
                deliverNotificationSynchronously(
                    tabId: workspaceId,
                    surfaceId: panelId,
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
            return result
        }

        var result = "OK"
        v2MainSync {
            let tab: Tab?
            if let tabId = UUID(uuidString: tabArg) {
                tab = tabForSidebarMutation(id: tabId)
            } else {
                tab = resolveTab(from: tabArg, tabManager: tabManager)
            }
            guard let tab else {
                result = "ERROR: Tab not found"
                return
            }
            guard let panelId = UUID(uuidString: panelArg),
                  tab.panels[panelId] != nil else {
                result = "ERROR: Panel not found"
                return
            }
            deliverNotificationSynchronously(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func notifyTargetQueued(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        guard let tabId = UUID(uuidString: parts[0]) else {
            return "ERROR: notify_target_async requires workspace_uuid to be a UUID"
        }
        guard let surfaceId = UUID(uuidString: parts[1]) else {
            return "ERROR: notify_target_async requires surface_uuid to be a UUID"
        }

        let payload = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        let (title, subtitle, body) = parseNotificationPayload(payload)
#if DEBUG
        cmuxDebugLog(
            "socket.notifyTargetAsync.enqueue workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) coalesces=0"
        )
#endif
        TerminalMutationBus.shared.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            coalesces: false
        )
        return "OK"
    }

    func listNotifications() -> String {
        var result = ""
        v2MainSync {
            let lines = TerminalNotificationStore.shared.notifications.enumerated().map { index, notification in
                let surfaceText = notification.surfaceId?.uuidString ?? "none"
                let readText = notification.isRead ? "read" : "unread"
                let createdAt = Self.notificationFieldFormatter.createdAtISO8601(notification.createdAt)
                let tabTitle = Self.notificationFieldFormatter.listTrailingField(AppDelegate.shared?.tabTitle(for: notification.tabId) ?? "")
                return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)|\(createdAt)|\(tabTitle)"
            }
            result = lines.joined(separator: "\n")
        }
        return result.isEmpty ? "No notifications" : result
    }

    func clearNotifications(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            TerminalMutationBus.shared.enqueueClearAllNotifications()
            return "OK"
        }
        let parsed = parseOptions(trimmed)
        guard let tabOption = parsed.options["tab"],
              !tabOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ERROR: Usage: clear_notifications [--tab=X] [--panel=ID]"
        }
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: Tab not found"
        }
        let usage = "clear_notifications [--tab=X] [--panel=ID]"
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        if case .workspace(let tabId) = target {
            if let panelId = panelResolution.panelId {
                TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId, surfaceId: panelId)
            } else {
                TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId)
            }
        } else {
            let clearBoundary = TerminalMutationBus.shared.markNotificationClearBoundary()
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
                if let panelId = panelResolution.panelId {
                    guard tab.panels.keys.contains(panelId) else { return }
                    TerminalMutationBus.shared.discardPendingNotifications(
                        forTabId: tab.id,
                        surfaceId: panelId,
                        through: clearBoundary
                    )
                    TerminalNotificationStore.shared.clearNotifications(
                        forTabId: tab.id,
                        surfaceId: panelId,
                        discardQueuedNotifications: false
                    )
                } else {
                    TerminalMutationBus.shared.discardPendingNotifications(
                        forTabId: tab.id,
                        through: clearBoundary
                    )
                    TerminalNotificationStore.shared.clearNotifications(
                        forTabId: tab.id,
                        discardQueuedNotifications: false
                    )
                }
            }
        }
        return "OK"
    }

    private func parseNotificationPayload(_ args: String) -> (String, String, String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    func sendInput(_ text: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            // Unescape common escape sequences
            // Note: \n is converted to \r for terminal (Enter key sends \r)
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendInput")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    func sendInputToWorkspace(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_workspace <workspace_id> <text>" }

        let workspaceArg = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let text = parts[1]
        guard let workspaceId = UUID(uuidString: workspaceArg) else {
            return "ERROR: Invalid workspace ID"
        }

        var success = false
        var error: String?
        v2MainSync {
            guard let targetManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
                ?? (tabManager.tabs.contains(where: { $0.id == workspaceId }) ? tabManager : nil) else {
                error = "ERROR: Workspace not found"
                return
            }
            guard let tab = targetManager.tabs.first(where: { $0.id == workspaceId }) else {
                error = "ERROR: Workspace not found"
                return
            }

            guard let terminalPanel = sendableWorkspaceTerminalPanel(in: tab) else {
                error = "ERROR: No selected terminal in workspace"
                return
            }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendWorkspace")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    private func sendableWorkspaceTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        func selectedTerminalPanel(in paneId: PaneID) -> TerminalPanel? {
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = workspace.panelIdFromSurfaceId(selectedTab.id),
                  let terminalPanel = workspace.panels[panelId] as? TerminalPanel else {
                return nil
            }
            return terminalPanel
        }

        func isSelectedTerminalPanel(_ terminalPanel: TerminalPanel) -> Bool {
            guard let surfaceId = workspace.surfaceIdFromPanelId(terminalPanel.id) else {
                return false
            }
            return workspace.bonsplitController.allPaneIds.contains { paneId in
                workspace.bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
            }
        }

        if let focusedPane = workspace.bonsplitController.focusedPaneId,
           let terminalPanel = selectedTerminalPanel(in: focusedPane) {
            return terminalPanel
        }

        if let rememberedTerminal = workspace.lastRememberedTerminalPanelForConfigInheritance(),
           isSelectedTerminalPanel(rememberedTerminal) {
            return rememberedTerminal
        }

        for paneId in workspace.bonsplitController.allPaneIds {
            if let terminalPanel = selectedTerminalPanel(in: paneId) {
                return terminalPanel
            }
        }

        return nil
    }

    func sendInputToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_surface <id|idx> <text>" }

        let target = parts[0]
        let text = parts[1]

        var success = false
        var error: String?
        v2MainSync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            switch terminalPanel.sendInputResult(unescaped) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendSurface")
                success = true
            case .queued:
                success = true
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
                return
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
                return
            case .processExited:
                error = Self.terminalProcessExitedSocketError
                return
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            switch terminalPanel.sendNamedKeyResult(keyName) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendKey")
                success = true
            case .queued:
                success = true
            case .unknownKey:
                error = "ERROR: Unknown key '\(keyName)'"
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
            case .processExited:
                error = Self.terminalProcessExitedSocketError
            }
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send key"
    }

    func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        var error: String?
        v2MainSync {
            guard let terminalPanel = resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            switch terminalPanel.sendNamedKeyResult(keyName) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.sendKeyToSurface")
                success = true
            case .queued:
                success = true
            case .unknownKey:
                error = "ERROR: Unknown key '\(keyName)'"
            case .inputQueueFull:
                error = Self.terminalInputQueueFullSocketError
            case .surfaceUnavailable:
                error = Self.terminalSurfaceUnavailableSocketError
            case .processExited:
                error = Self.terminalProcessExitedSocketError
            }
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send key"
    }
}
