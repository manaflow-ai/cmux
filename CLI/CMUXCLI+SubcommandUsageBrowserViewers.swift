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



// MARK: - Usage text: agent hooks, browser, viewers
extension CMUXCLI {
    /// Usage text for agent hook, browser, and viewer subcommands.
    func browserViewerSubcommandUsage(_ command: String) -> String? {
        switch command {
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
        case "diff": return diffSubcommandUsage()
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
}
