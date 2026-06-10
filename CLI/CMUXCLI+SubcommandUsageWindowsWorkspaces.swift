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



// MARK: - Usage text: windows and workspaces
extension CMUXCLI {
    /// Usage text for window and workspace management subcommands.
    func windowWorkspaceSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "list-windows":
            return """
            Usage: cmux list-windows

            List open windows.
            """
        case "current-window":
            return """
            Usage: cmux current-window

            Print the currently selected window ID.
            """
        case "new-window":
            return """
            Usage: cmux new-window

            Create a new window.

            Example:
              cmux new-window
            """
        case "focus-window":
            return """
            Usage: cmux focus-window --window <id|ref|index>

            Focus (bring to front) the specified window.

            Flags:
              --window <id|ref|index>   Window to focus (required)

            Example:
              cmux focus-window --window 0
              cmux focus-window --window window:1
            """
        case "close-window":
            return """
            Usage: cmux close-window --window <id|ref|index>

            Close the specified window.

            Flags:
              --window <id|ref|index>   Window to close (required)

            Example:
              cmux close-window --window 0
              cmux close-window --window window:1
            """
        case "move-workspace-to-window":
            return """
            Usage: cmux move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>

            Move a workspace to a different window.

            Flags:
              --workspace <id|ref|index>   Workspace to move (required)
              --window <id|ref|index>      Target window (required)

            Example:
              cmux move-workspace-to-window --workspace workspace:2 --window window:1
            """
        case "move-surface":
            return """
            Usage: cmux move-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Move a surface to a different pane, workspace, or window.

            Flags:
              --surface <id|ref|index>   Surface to move (required unless passed positionally)
              --pane <id|ref|index>      Target pane
              --workspace <id|ref|index> Target workspace
              --window <id|ref|index>    Target window
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after moving

            Example:
              cmux move-surface --surface surface:1 --workspace workspace:2
              cmux move-surface surface:1 --pane pane:2 --index 0
            """
        case "reorder-surface":
            return """
            Usage: cmux reorder-surface [--surface <id|ref|index> | <id|ref|index>] [flags]

            Reorder a surface within its pane.

            Flags:
              --surface <id|ref|index>   Surface to reorder (required unless passed positionally)
              --workspace <id|ref|index> Workspace context
              --window <id|ref|index>    Window context for refs and indexes
              --before <id|ref|index>    Place before this surface
              --before-surface <id|ref|index>
                                       Alias for --before
              --after <id|ref|index>     Place after this surface
              --after-surface <id|ref|index>
                                       Alias for --after
              --index <n>                Place at this index
              --focus <true|false>       Focus the surface after reordering

            Example:
              cmux reorder-surface --surface surface:1 --index 0
              cmux reorder-surface --surface surface:3 --after surface:1
            """
        case "reorder-workspace":
            return """
            Usage: cmux reorder-workspace [--workspace <id|ref|index> | <id|ref|index>] [flags]

            Reorder a workspace within its window.

            Flags:
              --workspace <id|ref|index>   Workspace to reorder (required unless passed positionally)
              --index <n>                  Place at this index
              --before <id|ref|index>      Place before this workspace
              --before-workspace <id|ref|index>
                                         Alias for --before
              --after <id|ref|index>       Place after this workspace
              --after-workspace <id|ref|index>
                                         Alias for --after
              --window <id|ref|index>      Window context
              --dry-run                    Print the resolved final index without applying

            Example:
              cmux reorder-workspace --workspace workspace:2 --index 0
              cmux reorder-workspace --workspace workspace:3 --after workspace:1
              cmux reorder-workspace --workspace workspace:2 --index 0 --dry-run
            """
        case "reorder-workspaces":
            return String(localized: "cli.help.reorderWorkspaces", defaultValue: """
            Usage: cmux reorder-workspaces --order <id|ref|index>,<id|ref|index>,... [flags]

            Reorder workspaces within a window as one atomic batch. The comma-separated
            order is the final leading order inside the pinned and unpinned groups;
            unmentioned workspaces keep their relative order after listed peers in the
            same group.

            Flags:
              --order <refs>                Comma-separated workspace refs to place first
              --window <id|ref|index>       Window context
              --dry-run                     Print the resolved final indexes without applying

            Example:
              cmux reorder-workspaces --order workspace:1,workspace:11,workspace:31
              cmux reorder-workspaces --order workspace:11,workspace:1 --dry-run
            """)
        case "simulate-sidebar-drag":
            return """
            Usage: cmux simulate-sidebar-drag --window <id|ref|index> --from <ws> --to <ws> [flags]

            Drive deterministic sidebar drag-state mutations against a DEBUG build of
            the app, intended for headless profiling under xctrace (see the profile-pr
            skill in cmuxterm-hq). Sets dragState.draggedTabId to --from, ticks
            dragState.dropIndicator across the rows between --from and --to over
            --duration-ms in --steps increments, then clears both. Does NOT commit a
            reorder. Only available in DEBUG builds.

            Flags:
              --window <id|ref|index>      Window context (required)
              --from <id|ref|index>        Workspace to mark as the dragged tab (required)
              --to <id|ref|index>          Final target neighbor row (required)
              --duration-ms <n>            Total simulation duration (default: 1000)
              --steps <n>                  Number of indicator updates (default: row count between from and to)

            Example:
              cmux simulate-sidebar-drag --window window:1 --from workspace:1 --to workspace:25 --duration-ms 2000
              cmux simulate-sidebar-drag --window window:1 --from workspace:1 --to workspace:25 --steps 120 --duration-ms 2000
            """
        case "workspace-action":
            return """
            Usage: cmux workspace-action --action <name> [flags]

            Perform workspace context-menu actions from CLI/socket.

            Actions:
              pin | unpin
              rename | clear-name
              set-description | clear-description
              move-up | move-down | move-top
              close-others | close-above | close-below
              mark-read | mark-unread
              set-color | clear-color

            Flags:
              --action <name>              Action name (required if not positional)
              --workspace <id|ref|index>   Target workspace (default: current/$CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes
              --title <text>               Title for rename
              --color <name|#hex>          Color for set-color (name or #RRGGBB hex)
              --description <text>         Description for set-description

            Named colors:
              Red, Crimson, Orange, Amber, Olive, Green, Teal, Aqua,
              Blue, Navy, Indigo, Purple, Magenta, Rose, Brown, Charcoal

            Example:
              cmux workspace-action --workspace workspace:2 --action pin
              cmux workspace-action --action rename --title "infra"
              cmux workspace-action close-others
              cmux workspace-action --action set-color --color blue
              cmux workspace-action --action set-color --color "#C0392B"
              cmux workspace-action set-color Amber
              cmux workspace-action --action set-description --description "Ship checklist"
              cmux workspace-action --action set-description $'Ship checklist\n- verify build\n- post notes'
              cmux workspace-action clear-color
            """
        case "tab-action":
            return """
            Usage: cmux tab-action --action <name> [flags]

            Perform horizontal tab context-menu actions from CLI/socket.

            Actions:
              rename | clear-name
              close-left | close-right | close-others
              new-terminal-right | new-browser-right
              move-to-new-workspace
              reload | duplicate
              pin | unpin
              mark-unread

            Flags:
              --action <name>              Action name (required if not positional)
              --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
              --surface <id|ref|index>     Alias for --tab (backward compatibility)
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace/tab refs and indexes
              --title <text>               Title for rename (or pass trailing title text)
              --url <url>                  Optional URL for new-browser-right
              --focus <true|false>         Focus the destination when supported (default: false for move-to-new-workspace)

            Example:
              cmux tab-action --tab tab:3 --action pin
              cmux tab-action --action close-right
              cmux tab-action --tab tab:2 --action move-to-new-workspace
              cmux tab-action --tab tab:2 --action rename --title "build logs"
            """
        case "move-tab-to-new-workspace", "detach-tab":
            return Self.moveTabToNewWorkspaceCommandHelp
        case "rename-tab":
            return """
            Usage: cmux rename-tab [--workspace <id|ref|index>] [--tab <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--] <title>

            Compatibility alias for tab-action rename.

            Resolution order for target tab:
            1) --tab
            2) --surface
            3) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            4) currently focused tab (optionally within --workspace)

            Flags:
              --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref|index>         Tab target (supports tab:<n> or surface:<n>)
              --surface <id|ref|index>     Alias for --tab
              --window <id|ref|index>      Window context for workspace/tab refs and indexes
              --title <text>         Explicit title (or use trailing positional title)

            Examples:
              cmux rename-tab "build logs"
              cmux rename-tab --tab tab:3 "staging server"
              cmux rename-tab --workspace workspace:2 --surface surface:5 --title "agent run"
            """
        case "new-workspace":
            return """
            Usage: cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>]

            Create a new workspace in the caller's window.

            Flags:
              --name <title>       Set a custom name for the new workspace
              --description <text> Set a custom description for the new workspace
              --cwd <path>         Set the working directory for the new workspace
              --command <text>     Send text+Enter to the new workspace after creation
              --layout <json>      Create workspace with a predefined split layout (inline JSON).
                                   Uses the same schema as cmux.json layout definitions.
                                   When provided, --command is ignored (layout surfaces define their own commands).
              --window <id|ref|index>
                                   Target window (default: caller's window from $CMUX_WORKSPACE_ID/$CMUX_SURFACE_ID)
              --focus <true|false> Focus the new workspace (default: false)

            Example:
              cmux new-workspace
              cmux new-workspace --name "Build Server"
              cmux new-workspace --name "Launch" --description "Ship checklist"
              cmux new-workspace --cwd ~/projects/myapp
              cmux new-workspace --cwd . --command "npm test"
              cmux new-workspace --name "Dev" --layout '{"direction":"horizontal","split":0.5,"children":[{"pane":{"surfaces":[{"type":"terminal","command":"vim"}]}},{"pane":{"surfaces":[{"type":"terminal","command":"npm run start"}]}}]}'
            """
        case "list-workspaces":
            return """
            Usage: cmux list-workspaces [--window <id|ref|index>]

            List workspaces in a window.

            Flags:
              --window <id|ref|index>   Target window (default: caller/current window)

            Example:
              cmux list-workspaces
            """
        case "workspace":
            return """
            Usage: cmux workspace <subcommand> [flags]

            Canonical noun for workspace operations. Legacy verbs
            (new-workspace, list-workspaces, close-workspace,
            rename-workspace, select-workspace) keep working and print a
            one-time deprecation hint pointing here.

            Subcommands:
              list                    List workspaces in a window
              create [flags]          Create a workspace (same flags as new-workspace)
              close <workspace>       Close a workspace
              rename <workspace> --title <new>
              select <workspace>      Make a workspace active
              group <subcommand>      Workspace group operations (see cmux workspace-group --help)

            Examples:
              cmux workspace list --json
              cmux workspace create --name Build --cwd ~/projects/myapp
              cmux workspace close workspace:3
            """
        case "workspace-group":
            return """
            Usage: cmux workspace-group <subcommand> [flags]

            Manage collapsible workspace groups in the sidebar. Each group is
            owned by an "anchor" workspace; the group header IS the anchor's
            sidebar representation. Closing the anchor dissolves the group
            while preserving its other members as ungrouped workspaces.

            Subcommands:
              list [--json]
              create [--name <name>] [--cwd <path>] [--from <id>,<id>...]
                                        Defaults --from to the active sidebar
                                        selection / caller workspace when omitted.
              ungroup <group>           Dissolve a group, preserving all members
              delete <group>            Delete a group AND close every workspace
                                        inside it. Destructive. Use `ungroup` to
                                        keep the workspaces.
              rename <group> --name <new>
              collapse <group>
              expand <group>
              pin <group>
              unpin <group>
              add --group <group> --workspace <ws>
              remove --workspace <ws>
              set-anchor --group <group> --workspace <ws>
              new-workspace <group> [--placement afterCurrent|top|end]
                                        Create a new workspace in the group.
                                        Placement resolves first from per-cwd
                                        cmux.json `newWorkspacePlacement`, then
                                        from the global default. The default is
                                        afterCurrent; without an active
                                        in-group reference it behaves like top.
              set-color <group> [--hex #RRGGBB]
              set-icon <group> [--symbol <sf-symbol>]
              move <group> --to-index <n> | --before <group> | --after <group>
              focus <group>             Focus the group's anchor workspace

            <group> accepts a UUID or a workspace_group:N ref printed by `list`.

            All commands honor --json. Default keyboard shortcut for creating
            a group from the sidebar multi-selection is Cmd+Shift+G; rebind
            via Settings → Keyboard.
            """
        default:
            return nil
        }
    }

}
