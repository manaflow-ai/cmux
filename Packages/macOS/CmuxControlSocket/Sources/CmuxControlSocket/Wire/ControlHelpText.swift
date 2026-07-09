/// The full v1 `help` command-reference text returned over the control socket.
///
/// A pure, `Sendable` value: the composed string is built once from string
/// literals with no `TabManager`/`Workspace`/runtime state, so it lifted out of
/// the `TerminalController` god file byte-faithfully. The text has a release
/// body plus a `#if DEBUG` trailing test-only section; the package compiles
/// under the same Debug/Release configuration as the app target, so the DEBUG
/// section is present in Debug builds and absent in Release builds exactly as
/// before. The app-side `controlHelpTextV1()` witness returns
/// ``ControlHelpText/v1`` `.text`.
public struct ControlHelpText: Sendable {
    /// The composed v1 help-command reference string.
    public let text: String

    /// The canonical v1 help text value.
    public static let v1 = ControlHelpText()

    /// Composes the v1 help text (release body plus the DEBUG-only section).
    public init() {
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
        self.text = text
    }
}
