import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif



// MARK: - Usage text: tmux-compatible pane and buffer commands
extension CMUXCLI {
    /// Usage text for tmux-compatible pane and buffer subcommands.
    func tmuxCompatSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "capture-pane":
            return """
            Usage: cmux capture-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Surface context (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              cmux capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: cmux resize-pane [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref|index>        Pane to resize (default: focused pane)
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace/pane refs and indexes
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: cmux pipe-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Surface context (default: focused surface)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --command <command>    Shell command to run (or pass as trailing text)
            """
        case "wait-for":
            return """
            Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]

            Wait for or signal a named synchronization token.

            Flags:
              -S, --signal           Signal the token instead of waiting
              --timeout <seconds>    Wait timeout (default: 30)
            """
        case "swap-pane":
            return """
            Usage: cmux swap-pane --pane <id|ref|index> --target-pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]

            Swap two panes.

            Flags:
              --pane <id|ref|index>         Source pane (required)
              --target-pane <id|ref|index>  Target pane (required)
              --workspace <id|ref|index>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>       Window context for workspace/pane refs and indexes
              --focus <true|false>    Focus the target pane after swapping (default: false)
            """
        case "break-pane":
            return """
            Usage: cmux break-pane [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref|index>        Source pane
              --surface <id|ref|index>     Source surface
              --window <id|ref|index>      Window context for workspace/pane/surface refs and indexes
              --focus <true|false>   Focus the result (default: false)
              --no-focus             Compatibility alias for --focus false
            """
        case "join-pane":
            return """
            Usage: cmux join-pane --target-pane <id|ref|index> [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref|index>  Target pane (required)
              --workspace <id|ref|index>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref|index>         Source pane
              --surface <id|ref|index>      Source surface
              --window <id|ref|index>       Window context for workspace/pane/surface refs and indexes
              --focus <true|false>    Focus the result (default: false)
              --no-focus              Compatibility alias for --focus false
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: cmux \(command) [--window <id|ref|index>]

            Switch workspace selection (next/previous/last) in a window.
            """
        case "last-pane":
            return """
            Usage: cmux last-pane [--workspace <id|ref|index>] [--window <id|ref|index>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes
            """
        case "find-window":
            return """
            Usage: cmux find-window [--window <id|ref|index>] [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --window <id|ref|index>   Search/select within one window
              --content                 Search terminal content in addition to workspace titles
              --select                  Select the first match
            """
        case "clear-history":
            return """
            Usage: cmux clear-history [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Surface context (default: focused surface)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
            """
        case "set-hook":
            return """
            Usage: cmux set-hook [--list] [--unset <event>] | <event> <command>

            Manage tmux-compat hook definitions.

            Flags:
              --list            List configured hooks
              --unset <event>   Remove a hook by event name
            """
        case "popup":
            return """
            Usage: cmux popup

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "bind-key", "unbind-key", "copy-mode":
            return """
            Usage: cmux \(command)

            tmux compatibility placeholder. This command is currently not supported.
            """
        case "set-buffer":
            return """
            Usage: cmux set-buffer [--name <name>] [--] <text>

            Save text into a named tmux-compat buffer.

            Flags:
              --name <name>   Buffer name (default: default)
            """
        case "paste-buffer":
            return """
            Usage: cmux paste-buffer [--name <name>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref|index>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>    Surface context (default: focused surface)
              --window <id|ref|index>     Window context for workspace/surface refs and indexes
            """
        case "list-buffers":
            return """
            Usage: cmux list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: cmux respawn-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Surface context (default: focused surface)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --command <cmd>        Command text (or pass trailing command text)
            """
        case "display-message":
            return """
            Usage: cmux display-message [-p|--print] <text>

            Print text (or show it via notification bridge in parity mode).

            Flags:
              -p, --print   Print to stdout only
            """
        case "read-screen":
            return """
            Usage: cmux read-screen [flags]

            Read terminal text from a surface as plain text.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --scrollback           Include scrollback (not just visible viewport)
              --lines <n>            Limit to the last n lines (implies --scrollback)

            Example:
              cmux read-screen
              cmux read-screen --surface surface:2 --scrollback --lines 200
            """
        case "send":
            return """
            Usage: cmux send [flags] [--] <text>

            Send text to a terminal surface. Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes

            Example:
              cmux send "echo hello"
              cmux send --surface surface:2 "ls -la\\n"
            """
        case "send-key":
            return """
            Usage: cmux send-key [flags] [--] <key>

            Send a key event to a terminal surface.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes

            Example:
              cmux send-key enter
              cmux send-key --surface surface:2 ctrl+c
            """
        case "send-panel":
            return """
            Usage: cmux send-panel --panel <id|ref|index> [flags] [--] <text>

            Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --panel <id|ref|index>       Target panel (required)
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace/panel refs and indexes

            Example:
              cmux send-panel --panel surface:2 "echo hello\\n"
            """
        case "send-key-panel":
            return """
            Usage: cmux send-key-panel --panel <id|ref|index> [flags] [--] <key>

            Send a key event to a specific panel (surface).

            Flags:
              --panel <id|ref|index>       Target panel (required)
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace/panel refs and indexes

            Example:
              cmux send-key-panel --panel surface:2 enter
              cmux send-key-panel --panel surface:2 ctrl+c
            """
        default:
            return nil
        }
    }

}
