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



// MARK: - Usage text: notifications, status, progress, log, sidebar
extension CMUXCLI {
    /// Usage text for notification, status, progress, log, and sidebar subcommands.
    func notificationStatusSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "notify":
            return """
            Usage: cmux notify [flags]

            Send a notification to a workspace/surface.

            Flags:
              --title <text>         Notification title (default: "Notification")
              --subtitle <text>      Notification subtitle
              --body <text>          Notification body
              --workspace <id|ref|index>   Target workspace, except explicit surface UUIDs resolve globally
              --surface <id|ref|index>     Target surface (refs/indexes use workspace/window context)
              --window <id|ref|index>      Window context for workspace/surface refs and indexes

            Example:
              cmux notify --title "Build done" --body "All tests passed"
              cmux notify --title "Error" --subtitle "test.swift" --body "Line 42: syntax error"
              cmux notify --surface <uuid> --title "Build done"
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
            Usage: cmux mark-notification-read (--id <uuid> | --workspace <id|ref|index> [--surface <id|ref|index>] [--window <id|ref|index>] | --all)

            Mark notifications read without opening them. Exactly one selector is required.

            Flags:
              --id <uuid>           Mark one notification read
              --workspace <id|ref|index>  Mark notifications for a workspace
              --surface <id|ref|index>    Narrow --workspace to one surface
              --window <id|ref|index>     Window context for workspace/surface refs and indexes
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
            Usage: cmux clear-notifications [--workspace <id|ref|index>] [--window <id|ref|index>]

            Clear all queued notifications, or only the selected/targeted workspace when --window or --workspace is set.
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
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux set-status build "compiling" --icon hammer --color "#ff9500" --priority 80
              cmux set-status deploy "v1.2.3" --workspace workspace:2
            """)
        case "clear-status":
            return """
            Usage: cmux clear-status <key> [flags]

            Remove a sidebar status entry by key.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux clear-status build
            """
        case "list-status":
            return """
            Usage: cmux list-status [flags]

            List all sidebar status entries for a workspace.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

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
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux set-progress 0.5 --label "Building..."
              cmux set-progress 1.0 --label "Done"
            """
        case "clear-progress":
            return """
            Usage: cmux clear-progress [flags]

            Clear the sidebar progress bar for a workspace.

            Flags:
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

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
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

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
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

            Example:
              cmux clear-log
            """
        case "list-log":
            return """
            Usage: cmux list-log [flags]

            List sidebar log entries for a workspace.

            Flags:
              --limit <n>            Show only the last N entries
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

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
              --workspace <id|ref|index>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --window <id|ref|index>      Window context for workspace refs and indexes

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
        case "sidebar":
            return String(localized: "cli.sidebar.usage", defaultValue: """
            Usage: cmux sidebar <validate|reload|select> [name|--all] [--json]

            Validate, reload, or select custom left sidebars from ~/.config/cmux/sidebars.
            Swift files win over JSON files with the same base name.

            Commands:
              validate [name]   Validate all custom sidebars, or one named sidebar
              reload [name]     Validate all sidebars, then reload every valid one
              select <name>     Validate and activate one custom sidebar

            Examples:
              cmux sidebar validate
              cmux sidebar reload --all
              cmux sidebar select finder.tree
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
        default:
            return nil
        }
    }

}
