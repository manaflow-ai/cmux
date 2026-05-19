import Foundation

extension CMUXCLI {
    /// Return the help/usage text for a subcommand, or nil if the command is unknown.
    func subcommandUsage(_ command: String) -> String? {
        switch command {
        case "ping":
            return """
            Usage: cmux ping

            Check connectivity to the cmux socket server.
            """
        case "capabilities":
            return """
            Usage: cmux capabilities

            Print server capabilities as JSON.
            """
        case "events":
            return """
            Usage: cmux events [options]

            Stream cmux events as newline-delimited JSON.

            Options:
              --after <seq>          Replay retained events after this sequence
              --cursor-file <path>   Read the starting sequence from a file and update it after each event
              --name <event>         Filter by event name, repeatable
              --category <name>      Filter by category, repeatable
              --reconnect            Reconnect forever and resume from the last received sequence
              --limit <n>            Exit after printing n event frames
              --no-ack               Do not print the subscription ack frame
              --no-heartbeat         Do not print heartbeat frames

            Examples:
              cmux events --category notification
              cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect
              cmux events --after 42 --name feed.item.received
            """
        case "auth":
            return """
            Usage: cmux auth <status|login|logout>

            status   Print whether the user is signed in (add `cmux --json` for JSON).
            login    Open the sign-in popup on the cmux web app and wait for it to finish.
            logout   Clear the current session.
            """
        case "login":
            return """
            Usage: cmux login

            Alias for `cmux auth login`.
            """
        case "logout":
            return """
            Usage: cmux logout

            Alias for `cmux auth logout`.
            """
        case "vm", "cloud":
            return """
            Usage: cmux \(command) <new|ls|rm|exec|shell|attach|ssh|ssh-info> [args...]

            Manage cloud VMs. `cloud` is an alias for `vm`. Requires `cmux auth login`.

            Subcommands:
              ls                        List your cloud VMs.
              new [--image <template>] [--provider <provider>] [--detach|-d]
                                        Create a new VM. By default drops you into a shell on
                                        the VM (like `docker run -it`). Pass --detach/-d to
                                        just print the id and exit (scripting primitive).
              shell <id>                Drop into an interactive shell on an existing VM.
                                        Alias: `attach <id>`.
              ssh <id>                  Drop into a cmux-managed SSH workspace for an existing
                                        VM, using the same session path as `cmux ssh`.
              ssh-info <id>             Print SSH connection details when the Cloud VM
                                        exposes SSH.
              rm <id>                   Destroy a VM.
              exec <id> -- <command...> Run a shell command inside the VM and print stdout.

            Env:
              CMUX_VM_API_BASE_URL       Override the backend origin (default: the cmux website).
                                         `bun run dev` derives this from CMUX_PORT/PORT for
                                         local testing from the web worktree.

            Example:
              cmux vm new
              cmux vm ls
              cmux cloud exec <id> -- echo hello
              cmux vm rm <id>
            """
        case "rpc":
            return """
            Usage: cmux rpc <method> [json-params]

            Call a raw v2 method with an optional JSON object for params.
            Example: cmux rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'
            """
        case "help":
            return """
            Usage: cmux help

            Show top-level CLI usage and command list.
            Also works without a running cmux app or socket.
            """
        case "docs":
            return docsUsage()
        case "settings":
            return settingsUsage()
        case "config":
            return configUsage()
        case "welcome":
            return """
            Usage: cmux welcome

            Show a welcome screen with the cmux logo and useful shortcuts.
            Auto-runs once on first launch.
            """
        case "shortcuts":
            return """
            Usage: cmux shortcuts

            Open the Settings window to Keyboard Shortcuts.
            """
        case "disable-browser":
            return """
            Usage: cmux disable-browser [--json]

            Disable cmux browser creation and link interception. This overrides
            browser settings from cmux.json until re-enabled.
            """
        case "enable-browser":
            return """
            Usage: cmux enable-browser [--json]

            Re-enable cmux browser creation and link interception.
            """
        case "browser-status":
            return """
            Usage: cmux browser-status [--json]

            Print whether cmux browser creation and link interception are enabled.
            """
        case "restore-session":
            return """
            Usage: cmux restore-session

            Reopen the previous saved cmux session.

            If the app is already running, this restores the last saved session into the current app.
            If the app is not running, this launches cmux and lets startup restore reopen the saved session.
            """
        case "feedback":
            return """
            Usage: cmux feedback
                   cmux feedback --email <email> --body <text> [--image <path> ...]

            Without args, open the Send Feedback modal in the running app.

            With args, submit feedback through the app using the same feedback pipeline as the modal.

            Flags:
              --email <email>   Contact email for follow-up
              --body <text>     Feedback body
              --image <path>    Attach an image file, repeat for multiple images

            Coding agents:
              Double check with the end user before sending anything. Review the message and attachments for secrets,
              private code, credentials, tokens, and other sensitive information first.
            """
        case "feed":
            return """
            Usage: cmux feed tui [--opentui|--legacy]
                   cmux feed clear [--yes|-y]

            Open the keyboard-first Feed TUI or manage persisted Feed workstream history.

            TUI options:
              --opentui        Force the OpenTUI implementation and fail if unavailable
              --legacy         Force the older built-in Swift TUI
            """
        case "hooks":
            return """
            Usage: cmux hooks setup [agent] [--agent <name>] [--yes|-y]
                   cmux hooks uninstall [agent] [--agent <name>] [--yes|-y]
                   cmux hooks <agent> install [--yes|-y] (opencode supports --project)
                   cmux hooks <agent> uninstall [--yes|-y] (opencode supports --project)
                   cmux hooks <agent> <event> [flags]
                   cmux hooks feed --source <agent> [--event <event>]

            Manage and run cmux agent hooks without adding one top-level command per
            agent. Claude Code hooks are injected automatically by the cmux Claude wrapper.

            Agents:
              codex, opencode, pi, amp, cursor, gemini, rovodev (alias: rovo), hermes-agent, copilot, codebuddy, factory, qoder

            Hook targets:
              setup              Install hooks for all supported agents on PATH
              uninstall          Remove hooks for all supported agents
              <agent> install    Install one agent integration
              <agent> uninstall  Remove one agent integration
              <agent> <event>    Internal hook entrypoint used by generated configs
              feed               Internal Feed decision bridge

            Generated files:
              ~/.config/opencode/plugins/cmux-session.js
              ~/.config/opencode/plugins/cmux-feed.js
              ~/.pi/agent/extensions/cmux-session.ts
              ~/.config/amp/plugins/cmux-session.ts
              See docs/agent-hooks.md for the full integration matrix.

            Examples:
              cmux hooks setup
              cmux hooks setup --agent codex
              cmux hooks setup rovo
              cmux hooks uninstall rovo
              cmux hooks codex install
              cmux hooks opencode install --project
              cmux hooks uninstall
            """
        case "themes":
            return """
            Usage: cmux themes
                   cmux themes list
                   cmux themes set <theme>
                   cmux themes set --light <theme> [--dark <theme>]
                   cmux themes set --dark <theme> [--light <theme>]
                   cmux themes clear

            When run in a TTY, `cmux themes` opens an interactive theme picker with
            live app preview. Use `cmux themes list` for a plain listing.

            The picker previews the selected theme across the running cmux app and
            lets you apply it to the light theme, dark theme, or both defaults.

            Commands:
              list                      List available themes and mark the current light/dark defaults
              set <theme>               Set the same theme for both light and dark appearance
              set --light <theme>       Set the light appearance theme
              set --dark <theme>        Set the dark appearance theme
              clear                     Remove the cmux theme override and fall back to other config

            Examples:
              cmux themes
              cmux themes list
              cmux themes set "Catppuccin Mocha"
              cmux themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
              cmux themes clear
            """
        case "claude-teams":
            return String(localized: "cli.claude-teams.usage", defaultValue: """
            Usage: cmux claude-teams [claude-args...]

            Launch Claude Code with agent teams enabled.

            This command:
              - defaults Claude teammate mode to auto
              - sets a tmux-like environment so Claude auto mode uses cmux splits
              - sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to claude

            The tmux shim translates supported tmux window/pane commands into cmux
            workspace and split operations in the current cmux session.

            Examples:
              cmux claude-teams
              cmux claude-teams --continue
              cmux claude-teams --model sonnet
            """)
        case "codex-teams":
            return String(localized: "cli.codex-teams.usage", defaultValue: """
            Usage: cmux codex-teams [codex-args...]

            Launch Codex with cmux-managed subagent panes.

            This command:
              - starts a private Codex app-server on localhost
              - launches the root Codex TUI against that app-server
              - watches live Codex thread-spawn subagents
              - opens subagents up to depth 2 as native cmux splits
              - forwards all remaining arguments to codex

            Examples:
              cmux codex-teams
              cmux codex-teams --model gpt-5.4
              cmux codex-teams resume --last
            """)
        case "omo":
            return String(localized: "cli.omo.usage", defaultValue: """
            Usage: cmux omo [opencode-args...]

            Launch OpenCode with oh-my-openagent in a cmux-aware environment.

            oh-my-openagent orchestrates multiple AI models as specialized agents in
            parallel. This command sets up a tmux shim so agent panes become native
            cmux splits with sidebar metadata and notifications.

            This command:
              - sets a tmux-like environment so oh-my-openagent uses cmux splits
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to opencode

            The tmux shim translates tmux window/pane commands into cmux workspace
            and split operations in the current cmux session.

            Examples:
              cmux omo
              cmux omo --continue
              cmux omo --model claude-sonnet-4-6
            """)
        case "omx":
            return String(localized: "cli.omx.usage", defaultValue: """
            Usage: cmux omx [omx-args...]

            Launch Oh My Codex (OMX) with native cmux pane integration.

            OMX is a multi-agent orchestration layer for OpenAI Codex CLI. This
            command sets up a tmux shim so OMX team mode, HUD, and agent panes
            become native cmux splits.

            This command:
              - sets a tmux-like environment so OMX uses cmux splits
              - prepends a private tmux shim to PATH
              - forwards all remaining arguments to omx

            Install: npm install -g oh-my-codex

            Examples:
              cmux omx
              cmux omx --madmax --high
              cmux omx team
            """)
        case "omc":
            return String(localized: "cli.omc.usage", defaultValue: """
            Usage: cmux omc [omc-args...]

            Launch Oh My Claude Code (OMC) with native cmux pane integration.

            OMC is a multi-agent orchestration system for Claude Code with
            specialized agents, smart model routing, and team pipelines. This
            command sets up a tmux shim so OMC team mode and agent panes become
            native cmux splits.

            This command:
              - sets a tmux-like environment so OMC uses cmux splits
              - prepends a private tmux shim to PATH
              - injects NODE_OPTIONS restore module for Claude compatibility
              - forwards all remaining arguments to omc

            Install: npm install -g oh-my-claude-sisyphus

            Examples:
              cmux omc
              cmux omc team 3:claude "implement feature"
              cmux omc --watch
            """)
        case "identify":
            return """
            Usage: cmux identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Caller surface context (default: $CMUX_SURFACE_ID)
              --no-caller                  Omit caller context from the request
            """
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

            Example:
              cmux reorder-workspace --workspace workspace:2 --index 0
              cmux reorder-workspace --workspace workspace:3 --after workspace:1
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
            Usage: cmux rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] [--] <title>

            Compatibility alias for tab-action rename.

            Resolution order for target tab:
            1) --tab
            2) --surface
            3) $CMUX_TAB_ID / $CMUX_SURFACE_ID
            4) currently focused tab (optionally within --workspace)

            Flags:
              --workspace <id|ref>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
              --tab <id|ref>         Tab target (supports tab:<n> or surface:<n>)
              --surface <id|ref>     Alias for --tab
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
            Usage: cmux list-workspaces

            List workspaces in the current window.

            Example:
              cmux list-workspaces
            """
        case "ssh":
            return """
            Usage: cmux ssh <destination> [flags] [-- <remote-command-args>]

            Create a new workspace, mark it as remote-SSH, and start an SSH session in that workspace.
            cmux will also establish a local SSH proxy endpoint so browser traffic can egress from the remote host.

            Flags:
              --name <title>          Optional workspace title
              --port <n>              SSH port
              --identity <path>       SSH identity file path
              --ssh-option <opt>      Extra SSH -o option (repeatable)
              --no-focus              Create workspace without switching to it

            Example:
              cmux ssh dev@my-host
              cmux ssh dev@my-host --name "gpu-box" --port 2222 --identity ~/.ssh/id_ed25519
              cmux ssh dev@my-host --ssh-option UserKnownHostsFile=/dev/null --ssh-option StrictHostKeyChecking=no
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
              --focus <true|false>   Focus the new split (default: false)

            Example:
              cmux new-split right
              cmux new-split down --workspace workspace:1
            """
        case "list-panes":
            return """
            Usage: cmux list-panes [--workspace <id|ref>]

            List panes in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panes
              cmux list-panes --workspace workspace:2
            """
        case "list-pane-surfaces":
            return """
            Usage: cmux list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]

            List surfaces in a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Restrict to a specific pane (default: focused pane)

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
              cmux top --sort cpu
              cmux top --format tsv | sort -t $'\\t' -nrk1,1
              cmux top --workspace workspace:2 --processes
              cmux --json top --all
            """
        case "focus-pane":
            return """
            Usage: cmux focus-pane [--pane <id|ref> | <id|ref>] [flags]

            Focus the specified pane.

            Flags:
              --pane <id|ref>          Pane to focus (required unless passed positionally)
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)

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
              --workspace <id|ref>                Target workspace (default: $CMUX_WORKSPACE_ID)
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
              --type <terminal|browser>   Surface type (default: terminal)
              --pane <id|ref>             Target pane
              --workspace <id|ref>        Target workspace (default: $CMUX_WORKSPACE_ID)
              --url <url>                 URL for browser surfaces
              --focus <true|false>        Focus the new surface (default: false)

            Example:
              cmux new-surface
              cmux new-surface --type browser --pane pane:1 --url https://example.com
            """
        case "close-surface":
            return """
            Usage: cmux close-surface [flags]

            Close a surface. Defaults to the focused surface if none specified.

            Flags:
              --surface <id|ref>     Surface to close (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

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
              --focus <true|false>   Focus the split-off surface (default: false)

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
              --focus <true|false>   Focus the split-off surface (default: false)

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
            Usage: cmux surface-health [--workspace <id|ref>]

            List health details for surfaces in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

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
              --workspace <id|ref>     Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>       Surface context (default: $CMUX_SURFACE_ID)
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
            Usage: cmux trigger-flash [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>]

            Trigger the unread flash indicator for a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
              --panel <id|ref>       Alias for --surface

            Example:
              cmux trigger-flash
              cmux trigger-flash --workspace workspace:2 --surface surface:3
            """
        case "list-panels":
            return """
            Usage: cmux list-panels [--workspace <id|ref>]

            List surfaces (panels) in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-panels
              cmux list-panels --workspace workspace:2
            """
        case "focus-panel":
            return """
            Usage: cmux focus-panel --panel <id|ref> [--workspace <id|ref>]

            Focus a specific panel (surface).

            Flags:
              --panel <id|ref>       Panel/surface to focus (required)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux focus-panel --panel surface:2
              cmux focus-panel --panel surface:5 --workspace workspace:2
            """
        case "close-workspace":
            return """
            Usage: cmux close-workspace --workspace <id|ref|index>

            Close the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to close (required)

            Example:
              cmux close-workspace --workspace workspace:2
            """
        case "select-workspace":
            return """
            Usage: cmux select-workspace --workspace <id|ref|index>

            Select (switch to) the specified workspace.

            Flags:
              --workspace <id|ref|index>   Workspace to select (required)

            Example:
              cmux select-workspace --workspace workspace:2
              cmux select-workspace --workspace 0
            """
        case "rename-workspace", "rename-window":
            return """
            Usage: cmux rename-workspace [--workspace <id|ref|index>] [--] <title>

            Rename a workspace. Defaults to the current workspace.
            tmux-compatible alias: rename-window

            Flags:
              --workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)

            Example:
              cmux rename-workspace "backend logs"
              cmux rename-window --workspace workspace:2 "agent run"
            """
        case "current-workspace":
            return """
            Usage: cmux current-workspace

            Print the currently selected workspace ID.
            """
        case "capture-pane":
            return """
            Usage: cmux capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]

            tmux-compatible alias for reading terminal text from a pane.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: $CMUX_SURFACE_ID)
              --scrollback           Include scrollback
              --lines <n>            Return only the last N lines (implies --scrollback)

            Example:
              cmux capture-pane --workspace workspace:2 --surface surface:1 --scrollback --lines 200
            """
        case "resize-pane":
            return """
            Usage: cmux resize-pane [--pane <id|ref>] [--workspace <id|ref>] [-L|-R|-U|-D] [--amount <n>]

            tmux-compatible pane resize command.

            Flags:
              --pane <id|ref>        Pane to resize (default: focused pane)
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              -L|-R|-U|-D            Direction (default: -R)
              --amount <n>           Resize amount (default: 1)
            """
        case "pipe-pane":
            return """
            Usage: cmux pipe-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <shell-command> | <shell-command>]

            Capture pane text and pipe it to a shell command via stdin.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
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
            Usage: cmux swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>] [--focus <true|false>]

            Swap two panes.

            Flags:
              --pane <id|ref>         Source pane (required)
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --focus <true|false>    Focus the target pane after swapping (default: false)
            """
        case "break-pane":
            return """
            Usage: cmux break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]

            Move a pane/surface out into its own pane context.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>        Source pane
              --surface <id|ref>     Source surface
              --focus <true|false>   Focus the result (default: false)
              --no-focus             Compatibility alias for --focus false
            """
        case "join-pane":
            return """
            Usage: cmux join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]

            Join a pane/surface into another pane.

            Flags:
              --target-pane <id|ref>  Target pane (required)
              --workspace <id|ref>    Workspace context (default: $CMUX_WORKSPACE_ID)
              --pane <id|ref>         Source pane
              --surface <id|ref>      Source surface
              --focus <true|false>    Focus the result (default: false)
              --no-focus              Compatibility alias for --focus false
            """
        case "next-window", "previous-window", "last-window":
            return """
            Usage: cmux \(command)

            Switch workspace selection (next/previous/last) in the current window.
            """
        case "last-pane":
            return """
            Usage: cmux last-pane [--workspace <id|ref>]

            Focus the previously focused pane in a workspace.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
            """
        case "find-window":
            return """
            Usage: cmux find-window [--content] [--select] [query]

            Find workspaces by title (and optionally terminal content).

            Flags:
              --content   Search terminal content in addition to workspace titles
              --select    Select the first match
            """
        case "clear-history":
            return """
            Usage: cmux clear-history [--workspace <id|ref>] [--surface <id|ref>]

            Clear terminal scrollback history.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
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
            Usage: cmux paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]

            Paste a named tmux-compat buffer into a surface.

            Flags:
              --name <name>         Buffer name (default: default)
              --workspace <id|ref>  Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>    Surface context (default: focused surface)
            """
        case "list-buffers":
            return """
            Usage: cmux list-buffers

            List tmux-compat buffers.
            """
        case "respawn-pane":
            return """
            Usage: cmux respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd> | <cmd>]

            Send a command (or default shell restart command) to a surface.

            Flags:
              --workspace <id|ref>   Workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Surface context (default: focused surface)
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
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)
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
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send "echo hello"
              cmux send --surface surface:2 "ls -la\\n"
            """
        case "send-key":
            return """
            Usage: cmux send-key [flags] [--] <key>

            Send a key event to a terminal surface.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux send-key enter
              cmux send-key --surface surface:2 ctrl+c
            """
        case "send-panel":
            return """
            Usage: cmux send-panel --panel <id|ref> [flags] [--] <text>

            Send text to a specific panel (surface). Escape sequences: \\n and \\r send Enter, \\t sends Tab.

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-panel --panel surface:2 "echo hello\\n"
            """
        case "send-key-panel":
            return """
            Usage: cmux send-key-panel --panel <id|ref> [flags] [--] <key>

            Send a key event to a specific panel (surface).

            Flags:
              --panel <id|ref>       Target panel (required)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux send-key-panel --panel surface:2 enter
              cmux send-key-panel --panel surface:2 ctrl+c
            """
        case "notify":
            return """
            Usage: cmux notify [flags]

            Send a notification to a workspace/surface.

            Flags:
              --title <text>         Notification title (default: "Notification")
              --subtitle <text>      Notification subtitle
              --body <text>          Notification body
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              cmux notify --title "Build done" --body "All tests passed"
              cmux notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
            """
        case "list-notifications":
            return """
            Usage: cmux list-notifications

            List queued notifications.
            """
        case "dismiss-notification":
            return String(localized: "cli.help.dismissNotification", defaultValue: """
            Usage: cmux dismiss-notification (--id <uuid> | --all-read)

            Remove one notification, or remove every already-read notification.

            Flags:
              --id <uuid>           Notification id to remove
              --all-read            Remove every already-read notification
              --json                Print JSON
              --id-format <mode>    refs, uuids, or both
            """)
        case "mark-notification-read":
            return String(localized: "cli.help.markNotificationRead", defaultValue: """
            Usage: cmux mark-notification-read (--id <uuid> | --workspace <id|ref> [--surface <id|ref>] | --all)

            Mark notifications read without opening them. Exactly one selector is required.

            Flags:
              --id <uuid>           Mark one notification read
              --workspace <id|ref>  Mark notifications for a workspace
              --surface <id|ref>    Narrow --workspace to one surface
              --all                 Mark every notification read
              --json                Print JSON
              --id-format <mode>    refs, uuids, or both
            """)
        case "open-notification":
            return String(localized: "cli.help.openNotification", defaultValue: """
            Usage: cmux open-notification --id <uuid>

            Focus the notification's workspace and surface, then mark the row read.

            Flags:
              --id <uuid>           Notification id to open
              --json                Print JSON
              --id-format <mode>    refs, uuids, or both
            """)
        case "jump-to-unread":
            return String(localized: "cli.help.jumpToUnread", defaultValue: """
            Usage: cmux jump-to-unread

            Focus the latest unread notification, matching the Notifications page action.

            Flags:
              --json                Print JSON
              --id-format <mode>    refs, uuids, or both
            """)
        case "clear-notifications":
            return """
            Usage: cmux clear-notifications

            Clear all queued notifications.
            """
        case "set-status":
            return String(localized: "cli.help.setStatus", defaultValue: """
            Usage: cmux set-status <key> <value> [flags]

            Set a sidebar status entry for a workspace. Status entries appear as
            pills in the sidebar tab row. Use a unique key so different tools
            (e.g. "claude_code", "build") can manage their own entries.

            Flags:
              --icon <name>          Icon name (e.g. "sparkle", "hammer")
              --color <#hex>         Pill color (e.g. "#ff9500")
              --priority <n>         Sort priority; higher appears first (default: 0)
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux set-status build "compiling" --icon hammer --color "#ff9500" --priority 80
              cmux set-status deploy "v1.2.3" --workspace workspace:2
            """)
        case "clear-status":
            return """
            Usage: cmux clear-status <key> [flags]

            Remove a sidebar status entry by key.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-status build
            """
        case "list-status":
            return """
            Usage: cmux list-status [flags]

            List all sidebar status entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-status
              cmux list-status --workspace workspace:2
            """
        case "set-progress":
            return """
            Usage: cmux set-progress <0.0-1.0> [flags]

            Set a progress bar in the sidebar for a workspace.

            Flags:
              --label <text>         Label shown next to the progress bar
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux set-progress 0.5 --label "Building..."
              cmux set-progress 1.0 --label "Done"
            """
        case "clear-progress":
            return """
            Usage: cmux clear-progress [flags]

            Clear the sidebar progress bar for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-progress
            """
        case "log":
            return """
            Usage: cmux log [flags] [--] <message>

            Append a log entry to the sidebar for a workspace.

            Flags:
              --level <level>        Log level: info, progress, success, warning, error (default: info)
              --source <name>        Source label (e.g. "build", "test")
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux log "Build started"
              cmux log --level error --source build "Compilation failed"
              cmux log --level success -- "All 42 tests passed"
            """
        case "clear-log":
            return """
            Usage: cmux clear-log [flags]

            Clear all sidebar log entries for a workspace.

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux clear-log
            """
        case "list-log":
            return """
            Usage: cmux list-log [flags]

            List sidebar log entries for a workspace.

            Flags:
              --limit <n>            Show only the last N entries
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux list-log
              cmux list-log --limit 5
            """
        case "sidebar-state":
            return """
            Usage: cmux sidebar-state [flags]

            Dump all sidebar metadata for a workspace (cwd, git branch, ports,
            status entries, progress, log entries).

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)

            Example:
              cmux sidebar-state
              cmux sidebar-state --workspace workspace:2
            """
        case "right-sidebar":
            return String(localized: "cli.rightSidebar.usage", defaultValue: """
            Usage: cmux right-sidebar <command> [flags]

            Control the right sidebar from the CLI.

            Commands:
              toggle                         Toggle right sidebar visibility
              show                           Show the right sidebar
              hide                           Hide the right sidebar
              focus                          Focus the current right sidebar mode
              set <files|find|vault|sessions|feed|dock>
                                             Show, switch mode, and focus
              mode                           Print {"visible":bool,"mode":string}
              files|find|vault|sessions|feed|dock
                                             Alias for show + set + focus

            Flags:
              --workspace <id|ref|index>     Target the window containing a workspace
              --window <id|ref|index>        Target a window
              --no-focus                     With set, switch mode without moving focus

            Examples:
              cmux right-sidebar toggle
              cmux right-sidebar set find
              cmux right-sidebar set vault --no-focus
              cmux right-sidebar mode
            """)
        case "set-app-focus":
            return """
            Usage: cmux set-app-focus <active|inactive|clear>

            Override app focus state for notification routing tests.

            Example:
              cmux set-app-focus inactive
              cmux set-app-focus clear
            """
        case "simulate-app-active":
            return """
            Usage: cmux simulate-app-active

            Trigger the app-active handler used by notification focus tests.
            """
        case "claude-hook":
            return """
            Usage: cmux claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | cmux claude-hook session-start
              echo '{}' | cmux claude-hook stop
            """
        case "codex":
            return """
            Usage: cmux codex <install-hooks|uninstall-hooks>

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install cmux hooks into ~/.codex/hooks.json
              uninstall-hooks   Remove cmux hooks from ~/.codex/hooks.json
            """
        case "browser":
            return """
            Usage: cmux browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.
            A surface can be passed as `--surface <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit surface.

            Subcommands:
              open|open-split|new [url] [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
                open/open-split/new default to $CMUX_WORKSPACE_ID when --workspace is omitted and --window is not set
                --focus defaults to false
              disable | enable | status
              goto|navigate <url> [--snapshot-after]
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              profiles <list|add|rename|clear|delete> [...]
              import [--interactive|--non-interactive|-y|--yes] [--from <browser>] [--profile <name>] [--all-profiles] [--to-profile <name|uuid>] [--create-profile] [--domain <domain>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--all]
              storage <local|session> <get|set|clear> [...]
              tab <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              viewport <width> <height>
              geolocation|geo <latitude> <longitude>
              offline <true|false>
              trace <start|stop> [path]
              network <route|unroute|requests> ...
                route <pattern> [--abort] [--body <text>]
                unroute <pattern>
              screencast <start|stop>
              input <mouse|keyboard|touch> [args...]
              input_mouse | input_keyboard | input_touch
              identify [--surface <id|ref|index>]

            Example:
              cmux browser open https://example.com
              cmux browser surface:1 navigate https://google.com
              cmux browser --surface surface:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `cmux browser --help`
        case "open-browser":
            return "Legacy alias for 'cmux browser open'. Run 'cmux browser --help' for details."
        case "navigate":
            return "Legacy alias for 'cmux browser navigate'. Run 'cmux browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'cmux browser back'. Run 'cmux browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'cmux browser forward'. Run 'cmux browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'cmux browser reload'. Run 'cmux browser --help' for details."
        case "get-url":
            return "Legacy alias for 'cmux browser get-url'. Run 'cmux browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'cmux browser focus-webview'. Run 'cmux browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'cmux browser is-webview-focused'. Run 'cmux browser --help' for details."
        case "open": return openSubcommandUsage()
        case "markdown":
            return """
            Usage: cmux markdown open <path> [options]
                   cmux markdown <path>       (shorthand for 'open')

            Open a markdown file in a formatted viewer panel with live file watching.
            The file is rendered with rich formatting (headings, code blocks, tables,
            lists, blockquotes) and automatically updates when the file changes on disk.

            Options:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Source surface to split from (default: focused surface)
              --window <id|ref|index>      Target window
              --direction <left|right|up|down>  Split direction (default: right)
              --focus <true|false>         Focus the markdown panel (default: false)

            Examples:
              cmux markdown open plan.md
              cmux markdown ~/project/CHANGELOG.md
              cmux markdown open ./docs/design.md --workspace 0
              cmux markdown open plan.md --direction down
            """
        default:
            return nil
        }
    }

    /// Dispatch help for a subcommand. Returns true if help was printed.
    func dispatchSubcommandHelp(command: String, commandArgs: [String]) -> Bool {
        guard commandArgs.contains("--help") || commandArgs.contains("-h") else { return false }
        guard let text = subcommandUsage(command) else { return false }
        print("cmux \(command)")
        print("")
        print(text)
        return true
    }

    func usage() -> String {
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux <path>                Open a directory in a new workspace (launches cmux if needed)
          cmux [global-options] <command> [options]

        Handle Inputs:
          Use UUIDs, short refs (window:1/workspace:2/pane:3/surface:4), or indexes where commands accept window, workspace, pane, or surface inputs.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD env var, then password saved in Settings.

        Agent Help:
          To change cmux settings, run `cmux docs settings` and `cmux settings path`; to add Dock controls, run `cmux docs dock`.
          Back up any existing cmux.json file to a timestamped .bak copy before editing.
          Use printed curl commands to fetch the latest docs/schema, and prefer Ghostty config for terminal behavior Ghostty already supports.
          Ghostty config lives at ~/.config/ghostty/config (controls terminal transparency, blur, font, theme, keybinds, etc.).
          `cmux reload-config` reloads BOTH Ghostty config and ~/.config/cmux/cmux.json and refreshes terminals in place. No app restart needed.

        Commands:
          welcome
          docs [settings|shortcuts|api|browser|agents|dock]
          settings [open [target]|path|docs|<target>]
          config <doctor|check|validate|path|paths|docs|documentation|reload>
          shortcuts
          disable-browser | enable-browser | browser-status
          restore-session
          open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
          feedback [--email <email> --body <text> [--image <path> ...]]
          feed tui|clear
          themes [list|set|clear]
          claude-teams [claude-args...]
          codex-teams [codex-args...]
          omo [opencode-args...]
          omx [omx-args...]
          omc [omc-args...]
          hooks setup|uninstall [--agent <name>]
          hooks <agent> <install|uninstall|event> [options; opencode supports --project]
          hooks feed --source <agent> [--event <event>]
          ping
          version
          capabilities
          events [--after <seq>] [--cursor-file <path>] [--name <event>] [--category <category>] [--reconnect] [--limit <n>] [--no-ack] [--no-heartbeat]
          auth <status|login|logout>
          login | logout                                      (aliases for auth login/logout)
          vm <new|ls|rm|exec|shell|ssh> [args...]    (alias: cloud)
          rpc <method> [json-params]
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>]
          workspace-action --action <name> [--workspace <id|ref|index>] [--title <text>] [--color <name|#hex>] [--description <text>]
          move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--focus <true|false>]
          list-workspaces
          new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>]
          ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [--ssh-option <opt>] [--no-focus] [-- <remote-command-args>]
          remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
          new-split <left|right|up|down> [--workspace <id|ref>] [--surface <id|ref>] [--panel <id|ref>] [--focus <true|false>]
          list-panes [--workspace <id|ref>]
          list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
          tree [--all] [--workspace <id|ref|index>]
          top [--all] [--workspace <id|ref|index>] [--processes] [--sort <cpu|mem|proc>] [--flat] [--format <tree|tsv>]
          focus-pane --pane <id|ref> [--workspace <id|ref>]
          new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref>] [--url <url>] [--focus <true|false>]
          new-surface [--type <terminal|browser>] [--pane <id|ref>] [--workspace <id|ref>] [--url <url>] [--focus <true|false>]
          close-surface [--surface <id|ref>] [--workspace <id|ref>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          split-off --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--focus <true|false>]
          tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--url <url>] [--focus <true|false>]
          surface resume <set|show|get|clear> [--workspace <id|ref>] [--surface <id|ref>]
          rename-tab [--workspace <id|ref>] [--tab <id|ref>] [--surface <id|ref>] <title>
          drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--focus <true|false>]
          refresh-surfaces
          reload-config
          surface-health [--workspace <id|ref>]
          debug-terminals
          trigger-flash [--workspace <id|ref>] [--surface <id|ref>]
          list-panels [--workspace <id|ref>]
          focus-panel --panel <id|ref> [--workspace <id|ref>]
          close-workspace --workspace <id|ref>
          select-workspace --workspace <id|ref>
          rename-workspace [--workspace <id|ref>] <title>
          rename-window [--workspace <id|ref>] <title>
          current-workspace
          read-screen [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref>] [--surface <id|ref>] <text>
          send-key [--workspace <id|ref>] [--surface <id|ref>] <key>
          send-panel --panel <id|ref> [--workspace <id|ref>] <text>
          send-key-panel --panel <id|ref> [--workspace <id|ref>] <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref>] [--surface <id|ref>]
          list-notifications
          dismiss-notification (--id <uuid> | --all-read)
          mark-notification-read (--id <uuid> | --workspace <id|ref> [--surface <id|ref>] | --all)
          open-notification --id <uuid>
          jump-to-unread
          clear-notifications
          right-sidebar <toggle|show|hide|focus|set|mode|files|find|vault|sessions|feed|dock> [--workspace <id|ref|index>] [--window <id|ref|index>] [--no-focus]
          set-status <key> <value> [--workspace <id|ref>] [--icon <name>] [--color <#hex>] [--priority <n>]
          clear-status <key> [--workspace <id|ref>]
          list-status [--workspace <id|ref>]
          set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref>]
          clear-progress [--workspace <id|ref>]
          log [--level <level>] [--source <name>] [--workspace <id|ref>] <message>
          clear-log [--workspace <id|ref>]
          list-log [--workspace <id|ref>] [--limit <n>]
          sidebar-state [--workspace <id|ref>]
          set-app-focus <active|inactive|clear>
          simulate-app-active

          # tmux compatibility commands
          capture-pane [--workspace <id|ref>] [--surface <id|ref>] [--scrollback] [--lines <n>]
          resize-pane --pane <id|ref> [--workspace <id|ref>] (-L|-R|-U|-D) [--amount <n>]
          pipe-pane --command <shell-command> [--workspace <id|ref>] [--surface <id|ref>]
          wait-for [-S|--signal] <name> [--timeout <seconds>]
          swap-pane --pane <id|ref> --target-pane <id|ref> [--workspace <id|ref>] [--focus <true|false>]
          break-pane [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]
          join-pane --target-pane <id|ref> [--workspace <id|ref>] [--pane <id|ref>] [--surface <id|ref>] [--focus <true|false>] [--no-focus]
          next-window | previous-window | last-window
          last-pane [--workspace <id|ref>]
          find-window [--content] [--select] <query>
          clear-history [--workspace <id|ref>] [--surface <id|ref>]
          set-hook [--list] [--unset <event>] | <event> <command>
          popup
          bind-key | unbind-key | copy-mode
          set-buffer [--name <name>] <text>
          list-buffers
          paste-buffer [--name <name>] [--workspace <id|ref>] [--surface <id|ref>]
          respawn-pane [--workspace <id|ref>] [--surface <id|ref>] [--command <cmd>]
          display-message [-p|--print] <text>

          markdown [open] <path> [--focus <true|false>] (open markdown file in formatted viewer panel with live reload)

          browser [--surface <id|ref|index> | <surface>] <subcommand> ...
          browser disable | enable | status
          browser open [url] [--focus <true|false>] (create browser split in caller's workspace; if surface supplied, behaves like navigate)
          browser open-split [url]
          browser goto|navigate <url> [--snapshot-after]
          browser back|forward|reload [--snapshot-after]
          browser url|get-url
          browser snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
          browser eval <script>
          browser wait [--selector <css>] [--text <text>] [--url-contains <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>]
          browser click|dblclick|hover|focus|check|uncheck|scroll-into-view <selector> [--snapshot-after]
          browser type <selector> <text> [--snapshot-after]
          browser fill <selector> [text] [--snapshot-after]   (empty text clears input)
          browser press|keydown|keyup <key> [--snapshot-after]
          browser select <selector> <value> [--snapshot-after]
          browser scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
          browser screenshot [--out <path>] [--json]
          browser get <url|title|text|html|value|attr|count|box|styles> [...]
          browser is <visible|enabled|checked> <selector>
          browser find <role|text|label|placeholder|alt|title|testid|first|last|nth> ...
          browser frame <selector|main>
          browser dialog <accept|dismiss> [text]
          browser download [wait] [--path <path>] [--timeout-ms <ms>]
          browser profiles <list|add|rename|clear|delete> [...]
          browser profiles clear <profile|--all> [--force]
          browser import [...]
          browser cookies <get|set|clear> [...]
          browser storage <local|session> <get|set|clear> [...]
          browser tab <new|list|switch|close|<index>> [...]
          browser console <list|clear>
          browser errors <list|clear>
          browser highlight <selector>
          browser state <save|load> <path>
          browser addinitscript <script>
          browser addscript <script>
          browser addstyle <css>
          browser identify [--surface <id|ref|index>]
          help

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in cmux terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/Library/Application Support/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }
}
