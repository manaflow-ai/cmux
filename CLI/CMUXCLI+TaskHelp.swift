import CmuxFoundation
import Foundation

/// Task-grouped `cmux help` output and `cmux help <topic>` topic views.
///
/// Each top-level command is listed once, under one task group. The full usage
/// text and every topic view render from the same per-group command lists.
extension CMUXCLI {
    private enum TaskHelpTopic: CaseIterable {
        case start
        case agents
        case navigate
        case inspect
        case customize
        case automation
        case browser
        case remote
        case diagnostics

        var name: String {
            switch self {
            case .start: return "start"
            case .agents: return "agents"
            case .navigate: return "navigate"
            case .inspect: return "inspect"
            case .customize: return "customize"
            case .automation: return "automation"
            case .browser: return "browser"
            case .remote: return "remote"
            case .diagnostics: return "diagnostics"
            }
        }

        var title: String {
            switch self {
            case .start: return String(localized: "cli.help.topic.start", defaultValue: "Start & Resume")
            case .agents: return String(localized: "cli.help.topic.agents", defaultValue: "Agents")
            case .navigate: return String(localized: "cli.help.topic.navigate", defaultValue: "Navigate & Arrange")
            case .inspect: return String(localized: "cli.help.topic.inspect", defaultValue: "Inspect")
            case .customize: return String(localized: "cli.help.topic.customize", defaultValue: "Customize")
            case .automation: return String(localized: "cli.help.topic.automation", defaultValue: "Automation")
            case .browser: return String(localized: "cli.help.topic.browser", defaultValue: "Browser")
            case .remote: return String(localized: "cli.help.topic.remote", defaultValue: "Remote")
            case .diagnostics: return String(localized: "cli.help.topic.diagnostics", defaultValue: "Diagnostics / Advanced")
            }
        }

        var aliases: [String] {
            switch self {
            case .start: return ["start", "resume", "start-resume", "start-and-resume"]
            case .agents: return ["agents", "agent"]
            case .navigate: return ["navigate", "arrange", "navigation", "navigate-arrange", "navigate-and-arrange"]
            case .inspect: return ["inspect", "inspection"]
            case .customize: return ["customize", "customise", "customization"]
            case .automation: return ["automation", "automate"]
            case .browser: return ["browser", "web"]
            case .remote: return ["remote", "remotes", "cloud"]
            case .diagnostics: return ["diagnostics", "diagnostic", "advanced", "diagnostics-advanced"]
            }
        }

        static func resolve(_ rawValue: String) -> Self? {
            let normalized = rawValue
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            return allCases.first { $0.aliases.contains(normalized) }
        }
    }

    private static var taskHelpTopicSummary: String {
        TaskHelpTopic.allCases
            .map { "  \($0.name)  \($0.title)" }
            .joined(separator: "\n")
    }

    private static var taskHelpTopicNames: String {
        TaskHelpTopic.allCases
            .map(\.name)
            .joined(separator: "|")
    }

    /// Output for `cmux help [topic]`. Anything other than exactly one known
    /// topic prints the top-level usage.
    func helpOutput(commandArgs: [String]) -> String {
        guard commandArgs.count == 1,
              let topic = TaskHelpTopic.resolve(commandArgs[0]) else {
            return usage()
        }
        return taskHelpUsage(topic)
    }

    /// Text for `cmux help --help`.
    func helpCommandUsage() -> String {
        return """
        \(String(localized: "cli.help.usage", defaultValue: "Usage: cmux help [topic]"))

        \(String(localized: "cli.help.description", defaultValue: "Show top-level CLI usage, or one task-focused command group."))

        \(String(localized: "cli.help.topics", defaultValue: "Topics:"))
        \(Self.taskHelpTopicSummary)

        \(String(localized: "cli.help.unknownTopic", defaultValue: "Unknown topics keep the top-level help behavior."))
        \(String(localized: "cli.help.noSocket", defaultValue: "Also works without a running cmux app or socket."))
        """
    }

    private func taskHelpUsage(_ topic: TaskHelpTopic) -> String {
        let commands = taskHelpCommandLines(topic)
            .map { "  \($0)" }
            .joined(separator: "\n")
        return """
        cmux help \(topic.name)

        \(topic.title):
        \(commands)

        \(String(localized: "cli.help.topic.commandUsage", defaultValue: "Run `cmux <command> --help` for command-specific usage."))
        """
    }

    private func taskHelpCommandLines(_ topic: TaskHelpTopic) -> [String] {
        let block: String
        switch topic {
        case .start: block = startCommandsHelp
        case .agents: block = agentsCommandsHelp
        case .navigate: block = navigateCommandsHelp
        case .inspect: block = inspectCommandsHelp
        case .customize: block = customizeCommandsHelp
        case .automation: block = automationCommandsHelp
        case .browser: block = browserCommandsHelp
        case .remote: block = remoteCommandsHelp
        case .diagnostics: block = diagnosticsCommandsHelp
        }
        return block.components(separatedBy: "\n")
    }

    func usage() -> String {
        let commandGroups = TaskHelpTopic.allCases
            .map { (topic: TaskHelpTopic) -> String in
                let commands = taskHelpCommandLines(topic)
                    .map { "    \($0)" }
                    .joined(separator: "\n")
                return "  \(topic.title):\n\(commands)"
            }
            .joined(separator: "\n\n")
        return """
        cmux - control cmux via Unix socket

        Usage:
          cmux <path>                Open a directory in a new workspace (launches cmux if needed)
          cmux [global-options] <command> [options]

        Targets:
          Commands that accept a window, workspace, pane, or surface take a UUID, a short ref (window:1/workspace:2/pane:3/surface:4), or an index.
          `tab-action` also accepts `tab:<n>` in addition to `surface:<n>`.
          Output defaults to refs; pass --id-format uuids or --id-format both to include UUIDs.

        Socket Auth:
          --password takes precedence, then CMUX_SOCKET_PASSWORD, then the password saved in Settings.

        Agent Help:
          cmux guide | cmux --skill
          cmux cloud guide | cmux cloud --skill
          Change cmux settings with `cmux docs settings` and `cmux settings path`; add Dock controls with `cmux docs dock`.
          Before editing, back up any existing cmux.json file to a timestamped .bak copy.
          Use printed curl commands to fetch the latest docs/schema; prefer Ghostty config for terminal behavior Ghostty already supports.
          Ghostty config lives at ~/.config/ghostty/config (terminal transparency, blur, font, theme, keybinds, etc.).
          `cmux reload-config` reloads BOTH Ghostty config and ~/.config/cmux/cmux.json, then refreshes terminals in place. No app restart needed.

        \(String(localized: "cli.help.taskHelp.heading", defaultValue: "Task Help:"))
          cmux help <\(Self.taskHelpTopicNames)>
          \(String(localized: "cli.help.taskHelp.description", defaultValue: "Show one command group without connecting to the cmux socket."))

        Commands:
        \(commandGroups)

        Environment:
          CMUX_WORKSPACE_ID   Auto-set in cmux terminals. Used as default --workspace for
                              ALL commands (send, list-panels, new-split, notify, etc.).
          CMUX_TAB_ID         Optional alias used by `tab-action`/`rename-tab` as default --tab.
          CMUX_SURFACE_ID     Auto-set in cmux terminals. Used as default --surface.
          CMUX_SOCKET_PATH    Override the Unix socket path. Without this, the CLI defaults
                              to ~/.local/state/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }

    private var startCommandsHelp: String {
        return """
        \(restoreCommandUsageLine)
        \(forkCommandUsageLine)
        restore-session
        \(String(localized: "cli.sessions.command", defaultValue: "sessions [list] [options]"))
        open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
        new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>] [--group <id|ref>] [--group-placement afterCurrent|top|end] [--group-reference <workspace>]
        local-tmux <start|attach|list|status|detach|close|cleanup> [session] [options]
        tmux attach [session] [options]                         (local-tmux alias)
        surface resume <set|show|get|clear> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        """
    }

    private var agentsCommandsHelp: String {
        return """
        agent-hibernation <on|off>
        claude-teams [claude-args...]
        codex-teams [codex-args...]
        omo [opencode-args...]
        omx [omx-args...]
        omc [omc-args...]
        hooks setup|uninstall [--agent <name>]
        hooks <agent> <install|uninstall|event> [options; opencode supports --project]
        hooks feed --source <agent> [--event <event>]
        \(localizedCoderouterAliases())
        \(localizedCoderouterCommands())
        ai-accounts <list|upload|remove> [--team <id>] [--json]
        """
    }

    private var navigateCommandsHelp: String {
        return """
        new-window
        focus-window --window <id>
        close-window --window <id>
        move-workspace-to-window --workspace <id|ref> --window <id|ref>
        reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>] [--dry-run]
        reorder-workspaces --order <id|ref|index>,<id|ref|index>,... [--window <id|ref|index>] [--dry-run]
        workspace-action --action <name> [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--color <name|#hex>] [--description <text>]
        workspace status [set <lane|auto>] [--workspace <id|ref|index>] [--window <id|ref|index>]
        move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--focus <true|false>]
        new-split <left|right|up|down> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>] [--command <text>] [--focus <true|false>]
        focus-pane --pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>]
        new-pane [--type <terminal|browser|simulator>] [--direction <left|right|up|down>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--url <url>] \(String(localized: "cli.browser.profile.option", defaultValue: "[--profile <name|uuid>]")) [--command <text>] [--focus <true|false>]
        new-surface [--type <terminal|browser|simulator|agent-session>] [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--url <url>] [--provider <codex|claude|opencode>] [--renderer <react|solid>] [--command <text>] [--focus <true|false>]
        close-surface [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>]
        move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
        split-off --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
        reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
        tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--url <url>] [--focus <true|false>]
        rename-tab [--workspace <id|ref|index>] [--tab <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <title>
        drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
        refresh-surfaces
        list-panels [--workspace <id|ref|index>] [--window <id|ref|index>]
        focus-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>]
        close-workspace --workspace <id|ref|index> [--window <id|ref|index>]
        select-workspace --workspace <id|ref|index> [--window <id|ref|index>]
        rename-workspace [--workspace <id|ref|index>] [--window <id|ref|index>] <title>
        rename-window [--workspace <id|ref|index>] [--window <id|ref|index>] <title>
        """
    }

    private var inspectCommandsHelp: String {
        return """
        diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--unstaged|--staged|--branch|--last-turn] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd <path>] [--base <ref>] [--focus <true|false>] [--no-focus] [--title <text>] [--layout <split|unified>] [--font-size <points>]
        identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--no-caller]
        list-windows
        current-window
        comments list [--repo <path>] [--all] [--json]
        review list [--repo <path>] [--json]
        review show [<id|latest>] [--repo <path>] [--json]
        review findings [<id|latest>] [--repo <path>] [--all] [--json]
        vault sessions [--agent <id>] [--folder <path>] [--limit <n>] [--json]
        vault search <query> [--limit <n>] [--json]
        vault checkpoints --agent <id> --session <id> [--json]
        vault checkpoint --agent <id> --session <id> [--name <text>] [--json]
        vault fork --agent <id> --session <id> (--checkpoint <id> | --turn <n>) [--open] [--json]
        list-workspaces [--window <id|ref|index>]
        list-panes [--workspace <id|ref|index>] [--window <id|ref|index>]
        list-pane-surfaces [--workspace <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>]
        current [--limit <1...200>] [--json]
        tree [--all] [--workspace <id|ref|index>] [--window <id|ref|index>]
        top [--all] [--workspace <id|ref|index>] [--window <id|ref|index>] [--processes] [--sort <cpu|mem|proc>] [--flat] [--format <tree|tsv>]
        memory [--all] [--workspace <id|ref|index>] [--groups <count>]
        surface-health [--workspace <id|ref|index>] [--window <id|ref|index>]
        current-workspace [--window <id|ref|index>]
        \(Self.readSelectionUsageLine)
        \(Self.readScreenUsageLine)
        sidebar-state [--workspace <id|ref|index>] [--window <id|ref|index>]
        markdown [open] <path> [--focus <true|false>] (open markdown file in formatted viewer panel with live reload)
        diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--cwd <path>] [--base <ref>] [--focus <true|false>] [--no-focus] [--title <text>] [--layout <split|unified>] [--font-size <points>] (open patch input or git source in a browser split)
        """
    }

    private var customizeCommandsHelp: String {
        return """
        guide | --skill
        welcome
        docs [settings|shortcuts|api|browser|agents|dock|sidebars]
        settings [open [target]|path|docs|<target>]
        config <doctor|check|validate|path|paths|docs|documentation|reload>
        shortcuts
        feedback [--email <email> --body <text> [--image <path> ...]]
        feed tui|clear
        themes [list|set|clear]
        reload-config
        right-sidebar <toggle|show|hide|focus|set|mode|files|find|vault|sessions|feed|dock|cloud|devices> [--workspace <id|ref|index>] [--window <id|ref|index>] [--no-focus]
        sidebar <validate|reload|select|open> [name]
        help
        """
    }

    private var automationCommandsHelp: String {
        let executionExchangeHelp = CmuxGlaedaExecutionLocalization().string(
            "glaeda.cli.taskHelp",
            defaultValue: "glaeda <request|observe> [options]"
        )
        return """
        events [--after <seq>] [--cursor-file <path>] [--name <event>] [--category <category>] [--reconnect] [--limit <n>] [--no-ack] [--no-heartbeat]
        automation <list|show|test|enable|disable|logs|reload> [args]
        \(executionExchangeHelp)
        todo <add|list|check|uncheck|start|rm|clear> [args] [--workspace <id|ref|index>] [--window <id|ref|index>]
        send [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <text>
        send-key [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <key>
        send-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] <text>
        send-key-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] <key>
        notify [--title <text>] [--subtitle <text>] [--body <text>] [--reply] [--clear] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        list-notifications
        dismiss-notification (--id <uuid> | --all-read)
        mark-notification-read (--id <uuid> | --workspace <id|ref|index> [--surface <id|ref|index>] [--window <id|ref|index>] | --all)
        open-notification --id <uuid>
        jump-to-unread
        clear-notifications [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        set-status <key> <value> [--workspace <id|ref|index>] [--window <id|ref|index>] [--icon <name>] [--color <#hex>] [--priority <n>]
        clear-status <key> [--workspace <id|ref|index>] [--window <id|ref|index>]
        list-status [--workspace <id|ref|index>] [--window <id|ref|index>]
        set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref|index>] [--window <id|ref|index>]
        clear-progress [--workspace <id|ref|index>] [--window <id|ref|index>]
        log [--level <level>] [--source <name>] [--workspace <id|ref|index>] [--window <id|ref|index>] <message>
        clear-log [--workspace <id|ref|index>] [--window <id|ref|index>]
        list-log [--workspace <id|ref|index>] [--window <id|ref|index>] [--limit <n>]
        """
    }

    private var browserCommandsHelp: String {
        return """
        disable-browser | enable-browser | browser-status
        browser [--surface <id|ref|index> | <surface>] <subcommand> ...
        browser disable | enable | status
        browser open [url] \(String(localized: "cli.browser.profile.option", defaultValue: "[--profile <name|uuid>]")) [--focus <true|false>] (create browser split in caller's workspace; if surface supplied, behaves like navigate)
        browser open-split [url] \(String(localized: "cli.browser.profile.option", defaultValue: "[--profile <name|uuid>]"))
        browser goto|navigate <url> [--snapshot-after]
        browser back|forward|reload [--snapshot-after]
        browser react-grab toggle [--surface <id>] [--return-to <terminal-surface>]
        browser devtools toggle|console [--surface <id>]
        browser focus-mode enter|exit|toggle [--surface <id>]
        \(String(localized: "cli.browser.designMode.help", defaultValue: "browser design-mode enable|disable|toggle|status [--surface <id>]"))
        browser zoom in|out|reset|<factor> [--surface <id>]   (factor sets an absolute zoom, e.g. 0.8 = 80%)
        browser history clear --force   (clears the default profile's history; mirrors the View menu)
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
        browser download list [--limit <1...25>] | download [wait] [--path <path>] [--timeout-ms <ms>]
        browser profiles <list|add|rename|clear|delete> [...]
        browser profiles clear <profile|--all> [--force]
        browser import [...]
        \(String(localized: "cli.browser.cookies.usage", defaultValue: "browser cookies <get|set|clear> [set: --http-only] [...]"))
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
        """
    }

    private var remoteCommandsHelp: String {
        return """
        auth <status|login|logout|team>
        login | logout                                      (aliases for auth login/logout)
        vm <base|new|ls|domains|tree|self|status|stats|resize|rename|pause|resume|snapshot|fork|restore|rm|run|route|agent|dev|prompt|exec|push|pull|wait|shell|tui|desktop|open|workspace|terminal|tab|layout|env|ports|tools|handoff|promote-template|attach|ssh|ssh-info> [args...]    (alias: cloud)
        remotes <list|add|remove> [--route <host:port>] [--tag <tag>] [--json]    (alias: remote)
        \(simulatorCommandUsageLine)
        \(iosCommandUsageLine)
        ssh <destination> [--transport <ssh|mosh>] [--name <title>] [--command <text>] [--port <n>] [--identity <path>] [-A|--forward-agent] [-a|--no-forward-agent] [--ssh-option <opt>] [--window <id|ref|index>] [--no-focus] [-- <remote-command-args>]
        mosh <destination> [--name <title>] [--command <text>] [--port <n>] [--identity <path>] [-A|--forward-agent] [-a|--no-forward-agent] [--ssh-option <opt>] [--window <id|ref|index>] [--no-focus] [-- <remote-command-args>]
        mosh-tmux <destination> [--session <name>] [--name <title>] [--command <text>] [--port <n>] [--identity <path>] [-A|--forward-agent] [-a|--no-forward-agent] [--ssh-option <opt>] [--window <id|ref|index>] [--no-focus]
        ssh-tmux <destination> [--port <n>] [--identity <path>] [--no-focus] [--new-window]
        ssh-session-list [--workspace <id|ref|index> | --all-workspaces]
        ssh-session-attach --session-id <id> [--workspace <id|ref|index>] [--pane <id|ref|index> | --split <left|right|up|down>]
        ssh-session-cleanup [--workspace <id|ref|index> | --all-workspaces] (--session-id <id> | --all)
        remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
        """
    }

    private var diagnosticsCommandsHelp: String {
        return """
        ping
        iroh-diag
        version
        \(String(localized: "sudo.cli.global_usage.run", defaultValue: "sudo run [-r reason] [-t timeout] (-c 'command' | script.sh | -)"))
        \(String(localized: "sudo.cli.global_usage.pending", defaultValue: "sudo pending"))
        \(String(localized: "sudo.cli.global_usage.setup_touch_id", defaultValue: "sudo setup-touch-id"))
        \(String(localized: "cli.socketControlStatus.command", defaultValue: "socket-status [--json]"))
        capabilities
        rpc <method> [json-params]
        debug-terminals
        trigger-flash [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        set-app-focus <active|inactive|clear>
        simulate-app-active
        simulate-sidebar-drag --window <id|ref|index> --from <ws> --to <ws> [--duration-ms <n>] [--steps <n>]
        # tmux compatibility commands
        capture-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]
        resize-pane --pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] (-L|-R|-U|-D) [--amount <n>]
        pipe-pane --command <shell-command> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        wait-for [-S|--signal] <name> [--timeout <seconds>]
        swap-pane --pane <id|ref|index> --target-pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
        break-pane [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
        join-pane --target-pane <id|ref|index> [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
        next-window | previous-window | last-window [--window <id|ref|index>]
        last-pane [--workspace <id|ref|index>] [--window <id|ref|index>]
        find-window [--window <id|ref|index>] [--content] [--select] <query>
        clear-history [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        set-hook [--list] [--unset <event>] | <event> <command>
        popup
        bind-key | unbind-key | copy-mode
        set-buffer [--name <name>] <text>
        list-buffers
        paste-buffer [--name <name>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
        respawn-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <cmd>]
        display-message [-p|--print] <text>
        """
    }
}
