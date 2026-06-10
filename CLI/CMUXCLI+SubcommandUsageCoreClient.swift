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



// MARK: - Usage text: core client, auth, agents, config
extension CMUXCLI {
    /// Usage text for core client, auth, agent, and configuration subcommands.
    func coreSubcommandUsage(_ command: String) -> String? {
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
              new [--image <template>] [--provider <provider>] [--window <id|ref|index>] [--detach|-d]
                                        Create a new VM. By default drops you into a shell on
                                        the VM (like `docker run -it`). Pass --detach/-d to
                                        just print the id and exit (scripting primitive).
              shell <id> [--window <id|ref|index>]
                                        Drop into an interactive shell on an existing VM.
                                        Alias: `attach <id>`.
              ssh <id> [--window <id|ref|index>]
                                        Drop into a cmux-managed SSH workspace for an existing
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
        case "agent-hibernation":
            return """
            Usage: cmux agent-hibernation <on|off> [--json]

            Enable or disable Agent Hibernation.
            Configure idle and live-terminal limits from Settings or cmux settings JSON.
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
              codex, grok, opencode, pi, omp, amp, cursor, gemini, kiro, antigravity (alias: agy), rovodev (alias: rovo), hermes-agent, copilot, codebuddy, factory, qoder

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
              ~/.omp/agent/extensions/cmux-omp-session.ts
              ~/.config/amp/plugins/cmux-session.ts
              ~/.kiro/agents/cmux.json
              See docs/agent-hooks.md for the full integration matrix.

            Examples:
              cmux hooks setup
              cmux hooks setup --agent codex
              cmux hooks setup rovo
              cmux hooks setup omp
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
            Usage: cmux identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--no-caller]

            Print server identity and caller context details.

            Flags:
              --workspace <id|ref|index>   Caller workspace context (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref|index>     Caller surface context (default: $CMUX_SURFACE_ID)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes
              --no-caller                  Omit caller context from the request
            """
        default:
            return nil
        }
    }

}
