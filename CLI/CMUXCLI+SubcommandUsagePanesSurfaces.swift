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



// MARK: - Usage text: SSH sessions, panes, splits, surfaces
extension CMUXCLI {
    /// Usage text for SSH session, pane, split, and surface subcommands.
    func paneSurfaceSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "ssh":
            return String(localized: "cli.help.ssh", defaultValue: """
            Usage: cmux ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            cmux will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              -A, --forward-agent     Forward the caller's SSH agent; also honors ForwardAgent yes from ssh_config
              -a, --no-forward-agent  Disable SSH agent forwarding for this workspace
              --ssh-option <opt>      Extra SSH -o option (repeatable)
              --window <id|ref|index> Target window for the managed workspace
              --no-focus              Create workspace without switching to it

            Example:
              cmux ssh dev@my-host
              cmux ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              cmux ssh dev@my-host --forward-agent
              cmux ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
            """)
        case "ssh-session-list":
            return """
            Usage: cmux ssh-session-list [--workspace <id|ref|index> | --all-workspaces]

            List persisted cmux ssh PTY sessions for a remote workspace.

            Flags:
              --workspace <id|ref|index>  Target workspace (default: $CMUX_WORKSPACE_ID)
              --all-workspaces            List sessions in every active remote workspace

            Example:
              cmux ssh-session-list
              cmux ssh-session-list --workspace workspace:2
              cmux ssh-session-list --all-workspaces
            """
        case "ssh-session-attach":
            return """
            Usage: cmux ssh-session-attach --session-id <id> [flags]

            Open a terminal surface attached to a persisted cmux ssh PTY session.

            Flags:
              --workspace <id|ref|index>  Target workspace (default: $CMUX_WORKSPACE_ID/current)
              --session-id <id>           Persisted SSH PTY session ID
              --pane <id|ref|index>       Target pane for a new surface
              --split <left|right|up|down> Create a new split instead of a surface
              --surface <id|ref|index>    Source surface for --split
              --focus <true|false>        Focus the attached surface (default: true)

            Example:
              cmux ssh-session-attach --session-id ssh-abc
              cmux ssh-session-attach --workspace workspace:2 --session-id ssh-abc --split right
            """
        case "ssh-session-cleanup":
            return """
            Usage: cmux ssh-session-cleanup [--workspace <id|ref|index> | --all-workspaces] (--session-id <id> | --all)

            Close persisted cmux ssh PTY sessions for a remote workspace.

            Flags:
              --workspace <id|ref|index>  Target workspace (default: $CMUX_WORKSPACE_ID)
              --all-workspaces            Target every active remote workspace
              --session-id <id>           Close one PTY session
              --all                       Close every persisted PTY session in the target scope

            Example:
              cmux ssh-session-cleanup --session-id ssh-abc
              cmux ssh-session-cleanup --workspace workspace:2 --all
              cmux ssh-session-cleanup --all-workspaces --all
            """
        case "remote-daemon-status":
            return """
            Usage: cmux remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]

            Show the embedded cmuxd-remote release manifest, local cache status, checksum verification state,
            and the GitHub attestation verification command for a target platform.

            Example:
              cmux remote-daemon-status
              cmux remote-daemon-status --os linux --arch arm64
            """
        case "new-split":
            return """
            Usage: cmux new-split <left|right|up|down> [flags]

            Split the current pane in the given direction.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface to split from (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --window <id|ref|index>
                                      Window context for workspace/surface refs and indexes
              --focus <true|false>   Focus the new split (default: false)

            Example:
              cmux new-split right
              cmux new-split down --workspace workspace:1
            """
        case "list-panes":
            return """
            Usage: cmux list-panes [--workspace <id|ref|index>] [--window <id|ref|index>]

            List panes in a workspace.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux list-panes
              cmux list-panes --workspace workspace:2
            """
        case "list-pane-surfaces":
            return """
            Usage: cmux list-pane-surfaces [--workspace <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>]

            List surfaces in a pane.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref|index>        Restrict to a specific pane (default: focused pane)
              --window <id|ref|index>      Window context for workspace/pane refs and indexes

            Example:
              cmux list-pane-surfaces
              cmux list-pane-surfaces --workspace workspace:2 --pane pane:1
            """
        case "tree":
            return """
            Usage: cmux tree [flags]

            Print the hierarchy of windows, workspaces, panes, and surfaces.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Show only one workspace
              --window <id|ref|index>      Show one window
              --json                        Structured JSON output

            Output:
              Text mode prints a box-drawing tree with markers:
              - ◀ active (true focused window/workspace/pane/surface path)
              - ◀ here (caller surface where `cmux tree` was invoked)
              - workspace [selected]
              - pane [focused]
              - surface [selected]
              Browser surfaces also include their current URL.

            Example:
              cmux tree
              cmux tree --all
              cmux tree --window window:2
              cmux tree --workspace workspace:2
              cmux --json tree --all
            """
        case "top":
            return """
            Usage: cmux top [flags]

            Print CPU and RAM usage by cmux window, workspace, pane, surface, status tag, and browser webview.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Show only one workspace
              --window <id|ref|index>      Show one window
              --processes                  Include process trees under windows, surfaces, webviews, and tags
              --sort <cpu|mem|proc>         Sort sibling rows by CPU, memory, or process count
              --flat                        Print independent rows for shell sorting
              --format <tree|tsv>           Text output format (tsv implies --flat)
              --json                        Structured JSON output

            Output:
              CPU comes from macOS process accounting and can exceed 100% across cores.
              Memory is summed from macOS physical footprint across the unique process IDs attributed to each tree node.
              Browser webviews are attributed through their WebKit content process PID.
              TSV columns are: cpu_percent, memory_bytes, process_count, kind, ref, parent_ref, title.

            Example:
              cmux top
              cmux top --all
              cmux top --window window:2
              cmux top --sort cpu
              cmux top --format tsv | sort -t $'\\t' -nrk1,1
              cmux top --workspace workspace:2 --processes
              cmux --json top --all
            """
        case "memory":
            return String(localized: "cli.help.memory", defaultValue: """
            Usage: cmux memory [flags]

            Diagnose cmux app memory separately from recursive terminal child-process RSS.

            Flags:
              --all                         Include all windows (default: current window only)
              --workspace <id|ref|index>   Limit workspace context for attribution labels
              --groups <count>              Number of child command groups to show (default: 12)
              --json                        Structured JSON output

            Output:
              App footprint is the direct cmux process physical footprint from macOS process accounting.
              Child RSS is recursive resident memory for descendants of the cmux app process,
              grouped by command name and attributed back to workspace, pane, and surface when known.

            Example:
              cmux memory
              cmux memory --groups 20
              cmux --json memory --all
            """)
        case "focus-pane":
            return """
            Usage: cmux focus-pane [--pane <id|ref|index> | <id|ref|index>] [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref|index>       Pane to focus (required unless passed positionally)
              --workspace <id|ref|index>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>     Window context for workspace/pane refs and indexes

            Example:
              cmux focus-pane --pane pane:2
              cmux focus-pane pane:1
              cmux focus-pane --pane pane:1 --workspace workspace:2
            """
        case "new-pane":
            return """
            Usage: cmux new-pane [flags]

            Create a new pane in the workspace.

            Flags:
              --type <terminal|browser>           Pane type (default: terminal)
              --direction <left|right|up|down>    Split direction (default: right)
              --workspace <id|ref|index>          Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>             Window context for workspace refs and indexes
              --url <url>                         URL for browser panes
              --focus <true|false>                Focus the new pane (default: false)

            Example:
              cmux new-pane
              cmux new-pane --type browser --direction down --url https://example.com
            """
        case "new-surface":
            return """
            Usage: cmux new-surface [flags]

            Create a new surface (tab) in a pane.

            Flags:
              --type <terminal|browser|agent-session>   Surface type (default: terminal)
              --pane <id|ref|index>       Target pane
              --workspace <id|ref|index>  Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>     Window context for workspace/pane refs and indexes
              --url <url>                 URL for browser surfaces
              --provider <codex|claude|opencode>
                                           Provider for agent-session surfaces (default: codex)
              --renderer <react|solid>    Renderer for agent-session surfaces (default: react)
              --working-directory <path>   Working directory for terminal and agent surfaces
              --focus <true|false>        Focus the new surface (default: false)

            Example:
              cmux new-surface
              cmux new-surface --type browser --pane pane:1 --url https://example.com
              cmux new-surface --type agent-session --provider claude --renderer solid --focus true
            """
        case "close-surface":
            return """
            Usage: cmux close-surface [flags]

            Close a surface. Defaults to the focused surface if none specified.

            Flags:
              --surface <id|ref|index>    Surface to close (default: $CMUX_SURFACE_ID)
              --panel <id|ref|index>      Alias for --surface
              --workspace <id|ref|index>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>     Window context for workspace/surface refs and indexes

            Example:
              cmux close-surface
              cmux close-surface --surface surface:3
            """
        case "drag-surface-to-split":
            return """
            Usage: cmux drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [flags]

            Drag a surface into a new split in the given direction.

            Flags:
              --surface <id|ref|index>     Surface to drag (required)
              --panel <id|ref|index>       Alias for --surface
              --workspace <id|ref|index>   Workspace context for ref/index resolution
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --focus <true|false>         Focus the split-off surface (default: false)

            Example:
              cmux drag-surface-to-split --surface surface:1 right
              cmux drag-surface-to-split --panel surface:2 down
            """
        case "split-off":
            return """
            Usage: cmux split-off --surface <id|ref|index> <left|right|up|down> [flags]

            Move an existing surface into a new split without changing focus by default.

            Flags:
              --surface <id|ref|index>     Surface to move (required)
              --panel <id|ref|index>       Alias for --surface
              --workspace <id|ref|index>   Workspace context for ref/index resolution
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --focus <true|false>         Focus the split-off surface (default: false)

            Example:
              cmux split-off --surface surface:1 right
              cmux split-off --workspace workspace:2 --surface surface:4 down
            """
        case "refresh-surfaces":
            return """
            Usage: cmux refresh-surfaces

            Refresh surface snapshots for the focused workspace.
            """
        case "reload-config":
            return """
            Usage: cmux reload-config

            Run the same configuration reload as the Reload Configuration shortcut.
            This reloads Ghostty config, re-reads ~/.config/cmux/cmux.json, and refreshes terminals.

            Example:
              cmux reload-config
            """
        case "surface-health":
            return """
            Usage: cmux surface-health [--workspace <id|ref|index>] [--window <id|ref|index>]

            List health details for surfaces in a workspace.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux surface-health
              cmux surface-health --workspace workspace:2
            """
        case "surface", "surface-resume":
            return """
            Usage: cmux surface resume set [flags] -- <argv...>
                   cmux surface resume set [flags] --shell <command>
                   cmux surface resume show [--json] [flags]
                   cmux surface resume get [--json] [flags]
                   cmux surface resume clear [flags]

            Attach restart command metadata to a terminal surface.
            Public CLI bindings are stored for inspection and manual restore.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Surface context (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace and surface refs/indexes
              --cwd <path>             Working directory for restore (default: $PWD)
              --name <name>            Display name for the binding
              --kind <kind>            Binding kind, for example agent or tmux
              --checkpoint <id>        Provider checkpoint or session id
              --checkpoint-id <id>     Same as --checkpoint and takes precedence
              --source <source>        Binding source label

            Examples:
              cmux surface resume set --kind tmux --shell "tmux attach -t work"
              cmux surface resume set --kind opencode --checkpoint ses_123 -- opencode --session ses_123
              cmux surface resume show --json
            """
        case "debug-terminals":
            return """
            Usage: cmux debug-terminals

            Print live Ghostty terminal runtime metadata across all windows and workspaces.
            Intended for debugging stray or detached terminal views.
            """
        case "trigger-flash":
            return """
            Usage: cmux trigger-flash [--workspace <id|ref|index>] [--surface <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>]

            Trigger the unread flash indicator for a surface.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Target surface (default: $CMUX_SURFACE_ID)
              --panel <id|ref|index>       Alias for --surface
              --window <id|ref|index>      Window context for workspace/surface refs and indexes

            Example:
              cmux trigger-flash
              cmux trigger-flash --workspace workspace:2 --surface surface:3
            """
        case "list-panels":
            return """
            Usage: cmux list-panels [--workspace <id|ref|index>] [--window <id|ref|index>]

            List surfaces (panels) in a workspace.

            Flags:
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux list-panels
              cmux list-panels --workspace workspace:2
            """
        case "focus-panel":
            return """
            Usage: cmux focus-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>]

            Focus a specific panel (surface).

            Flags:
              --panel <id|ref|index>       Panel/surface to focus (required)
              --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace/panel refs and indexes

            Example:
              cmux focus-panel --panel surface:2
              cmux focus-panel --panel surface:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: cmux close-workspace --workspace <id|ref|index> [--window <id|ref|index>]

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to close (required)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: cmux select-workspace --workspace <id|ref|index> [--window <id|ref|index>]

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux select-workspace --workspace workspace:2
              cmux select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: cmux rename-workspace [--workspace <id|ref|index>] [--window <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux rename-workspace "backend logs"
              cmux rename-window --workspace workspace:2 "agent run"
            """
        case "current-workspace":
            return """
            Usage: cmux current-workspace [--window <id|ref|index>]

            Print the selected workspace ID for a window.
            """
        default:
            return nil
        }
    }

}
