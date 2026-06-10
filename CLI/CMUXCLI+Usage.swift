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


// MARK: - Top-level usage text
extension CMUXCLI {
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
          docs [settings|shortcuts|api|browser|agents|dock|sidebars]
          settings [open [target]|path|docs|<target>]
          config <doctor|check|validate|path|paths|docs|documentation|reload>
          shortcuts
          disable-browser | enable-browser | browser-status
          agent-hibernation <on|off>
          restore-session
          open <path-or-url>... [--workspace <id|ref|index>] [--surface <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]
          diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--unstaged|--staged|--branch|--last-turn] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--cwd <path>] [--base <ref>] [--focus <true|false>] [--no-focus] [--title <text>] [--layout <split|unified>] [--font-size <points>]
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
          identify [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--no-caller]
          list-windows
          current-window
          new-window
          focus-window --window <id>
          close-window --window <id>
          move-workspace-to-window --workspace <id|ref> --window <id|ref>
          reorder-workspace --workspace <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--window <id|ref|index>] [--dry-run]
          reorder-workspaces --order <id|ref|index>,<id|ref|index>,... [--window <id|ref|index>] [--dry-run]
          workspace-action --action <name> [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--color <name|#hex>] [--description <text>]
          move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--focus <true|false>]
          list-workspaces [--window <id|ref|index>]
          new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--layout <json>] [--window <id|ref|index>] [--focus <true|false>]
          ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [-A|--forward-agent] [-a|--no-forward-agent] [--ssh-option <opt>] [--window <id|ref|index>] [--no-focus] [-- <remote-command-args>]
          ssh-session-list [--workspace <id|ref|index> | --all-workspaces]
          ssh-session-attach --session-id <id> [--workspace <id|ref|index>] [--pane <id|ref|index> | --split <left|right|up|down>]
          ssh-session-cleanup [--workspace <id|ref|index> | --all-workspaces] (--session-id <id> | --all)
          remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
          new-split <left|right|up|down> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
          list-panes [--workspace <id|ref|index>] [--window <id|ref|index>]
          list-pane-surfaces [--workspace <id|ref|index>] [--pane <id|ref|index>] [--window <id|ref|index>]
          tree [--all] [--workspace <id|ref|index>] [--window <id|ref|index>]
          top [--all] [--workspace <id|ref|index>] [--window <id|ref|index>] [--processes] [--sort <cpu|mem|proc>] [--flat] [--format <tree|tsv>]
          memory [--all] [--workspace <id|ref|index>] [--groups <count>]
          focus-pane --pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>]
          new-pane [--type <terminal|browser>] [--direction <left|right|up|down>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--url <url>] [--focus <true|false>]
          new-surface [--type <terminal|browser|agent-session>] [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--url <url>] [--provider <codex|claude|opencode>] [--renderer <react|solid>] [--focus <true|false>]
          close-surface [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>]
          move-surface --surface <id|ref|index> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--before <id|ref|index>] [--after <id|ref|index>] [--index <n>] [--focus <true|false>]
          split-off --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
          reorder-surface --surface <id|ref|index> (--index <n> | --before <id|ref|index> | --after <id|ref|index>) [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
          tab-action --action <name> [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--url <url>] [--focus <true|false>]
          surface resume <set|show|get|clear> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
          rename-tab [--workspace <id|ref|index>] [--tab <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <title>
          drag-surface-to-split --surface <id|ref|index> <left|right|up|down> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]
          refresh-surfaces
          reload-config
          surface-health [--workspace <id|ref|index>] [--window <id|ref|index>]
          debug-terminals
          trigger-flash [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
          list-panels [--workspace <id|ref|index>] [--window <id|ref|index>]
          focus-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>]
          close-workspace --workspace <id|ref|index> [--window <id|ref|index>]
          select-workspace --workspace <id|ref|index> [--window <id|ref|index>]
          rename-workspace [--workspace <id|ref|index>] [--window <id|ref|index>] <title>
          rename-window [--workspace <id|ref|index>] [--window <id|ref|index>] <title>
          current-workspace [--window <id|ref|index>]
          read-screen [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]
          send [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <text>
          send-key [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] <key>
          send-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] <text>
          send-key-panel --panel <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] <key>
          notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
          list-notifications
          dismiss-notification (--id <uuid> | --all-read)
          mark-notification-read (--id <uuid> | --workspace <id|ref|index> [--surface <id|ref|index>] [--window <id|ref|index>] | --all)
          open-notification --id <uuid>
          jump-to-unread
          clear-notifications [--workspace <id|ref|index>] [--window <id|ref|index>]
          right-sidebar <toggle|show|hide|focus|set|mode|files|find|vault|sessions|feed|dock> [--workspace <id|ref|index>] [--window <id|ref|index>] [--no-focus]
          sidebar <validate|reload|select> [name]
          set-status <key> <value> [--workspace <id|ref|index>] [--window <id|ref|index>] [--icon <name>] [--color <#hex>] [--priority <n>]
          clear-status <key> [--workspace <id|ref|index>] [--window <id|ref|index>]
          list-status [--workspace <id|ref|index>] [--window <id|ref|index>]
          set-progress <0.0-1.0> [--label <text>] [--workspace <id|ref|index>] [--window <id|ref|index>]
          clear-progress [--workspace <id|ref|index>] [--window <id|ref|index>]
          log [--level <level>] [--source <name>] [--workspace <id|ref|index>] [--window <id|ref|index>] <message>
          clear-log [--workspace <id|ref|index>] [--window <id|ref|index>]
          list-log [--workspace <id|ref|index>] [--window <id|ref|index>] [--limit <n>]
          sidebar-state [--workspace <id|ref|index>] [--window <id|ref|index>]
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

          markdown [open] <path> [--focus <true|false>] (open markdown file in formatted viewer panel with live reload)
          diff [patch-file|-] [--source <unstaged|staged|branch|last-turn>] [--cwd <path>] [--base <ref>] [--focus <true|false>] [--no-focus] [--title <text>] [--layout <split|unified>] [--font-size <points>] (open patch input or git source in a browser split)

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
                              to ~/.local/state/cmux/cmux.sock and auto-discovers tagged/debug sockets.
        """
    }

#if DEBUG
    func debugUsageTextForTesting() -> String {
        usage()
    }

    func debugFormatDebugTerminalsPayloadForTesting(
        _ payload: [String: Any],
        idFormat: CLIIDFormat = .refs
    ) -> String {
        formatDebugTerminalsPayload(payload, idFormat: idFormat)
    }
#endif
}
