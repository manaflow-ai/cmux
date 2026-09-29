import Foundation

/// User-facing reasons for typed "unavailable" and "failed" action
/// results. Keys live in Resources/Handlers.xcstrings (en, ja).
enum HandlerStrings {
    static var cloud: String { String(localized: "handlers.unavailable.cloud", defaultValue: "Cloud actions arrive with the Cloud wave; cmux-next has no Cloud client yet.", table: "Handlers", bundle: .module) }
    static var diffViewer: String { String(localized: "handlers.unavailable.diffViewer", defaultValue: "cmux-next has no diff viewer yet.", table: "Handlers", bundle: .module) }
    static var markdownViewer: String { String(localized: "handlers.unavailable.markdownViewer", defaultValue: "cmux-next has no Markdown viewer yet.", table: "Handlers", bundle: .module) }
    static var filePreview: String { String(localized: "handlers.unavailable.filePreview", defaultValue: "cmux-next has no file preview surface yet.", table: "Handlers", bundle: .module) }
    static var vscodeServer: String { String(localized: "handlers.unavailable.vscodeServer", defaultValue: "The inline VS Code server is not ported to cmux-next yet.", table: "Handlers", bundle: .module) }
    static var browserFocusMode: String { String(localized: "handlers.unavailable.browserFocusMode", defaultValue: "Browser focus mode is not built yet.", table: "Handlers", bundle: .module) }
    static var reactGrab: String { String(localized: "handlers.unavailable.reactGrab", defaultValue: "React Grab injection is not ported yet.", table: "Handlers", bundle: .module) }
    static var omnibarToggle: String { String(localized: "handlers.unavailable.omnibarToggle", defaultValue: "The address bar cannot be hidden yet.", table: "Handlers", bundle: .module) }
    static var browserHistory: String { String(localized: "handlers.unavailable.browserHistory", defaultValue: "cmux-next keeps no browser history store yet.", table: "Handlers", bundle: .module) }
    static var browserImport: String { String(localized: "handlers.unavailable.browserImport", defaultValue: "Importing browser data is not ported yet.", table: "Handlers", bundle: .module) }
    static var browserToggle: String { String(localized: "handlers.unavailable.browserToggle", defaultValue: "The cmux browser is always on in cmux-next; there is no setting to turn it off yet.", table: "Handlers", bundle: .module) }
    static var linkTarget: String { String(localized: "handlers.unavailable.linkTarget", defaultValue: "Link context menus do not pass a link to actions yet.", table: "Handlers", bundle: .module) }
    static var sectionScreenshot: String { String(localized: "handlers.unavailable.sectionScreenshot", defaultValue: "Section screenshots need a selection overlay that is not built yet.", table: "Handlers", bundle: .module) }
    static var browserProfiles: String { String(localized: "handlers.unavailable.browserProfiles", defaultValue: "Browser profile management is not built yet.", table: "Handlers", bundle: .module) }
    static var notificationsPanel: String { String(localized: "handlers.unavailable.notificationsPanel", defaultValue: "The notifications panel is not built yet.", table: "Handlers", bundle: .module) }
    static var clearLedger: String { String(localized: "handlers.unavailable.clearLedger", defaultValue: "The daemon has no command to clear the notification ledger; use Mark All Notifications as Read.", table: "Handlers", bundle: .module) }
    static var agentChat: String { String(localized: "handlers.unavailable.agentChat", defaultValue: "Agent chat views are not ported to cmux-next yet.", table: "Handlers", bundle: .module) }
    static var agentTeams: String { String(localized: "handlers.unavailable.agentTeams", defaultValue: "The Claude and Codex Teams launcher is not ported to cmux-next yet.", table: "Handlers", bundle: .module) }
    static var computerUse: String { String(localized: "handlers.unavailable.computerUse", defaultValue: "Computer Use integration is not ported to cmux-next yet.", table: "Handlers", bundle: .module) }
    static var noBrowser: String { String(localized: "handlers.failed.noBrowser", defaultValue: "No browser tab is focused.", table: "Handlers", bundle: .module) }
    static var noTerminal: String { String(localized: "handlers.failed.noTerminal", defaultValue: "No terminal tab is focused.", table: "Handlers", bundle: .module) }
    static var noPane: String { String(localized: "handlers.failed.noPane", defaultValue: "No pane is focused.", table: "Handlers", bundle: .module) }
    static var noWindow: String { String(localized: "handlers.failed.noWindow", defaultValue: "No window is open.", table: "Handlers", bundle: .module) }
    static var daemonOffline: String { String(localized: "handlers.failed.daemonOffline", defaultValue: "The cmux-tui daemon is not connected.", table: "Handlers", bundle: .module) }
    static var frontendBrowserTabs: String { String(localized: "handlers.failed.frontendBrowserTabs", defaultValue: "The daemon does not support app-rendered browser tabs.", table: "Handlers", bundle: .module) }
    static var noPageURL: String { String(localized: "handlers.failed.noPageURL", defaultValue: "The page has no URL.", table: "Handlers", bundle: .module) }
    static var hardReloadEngine: String { String(localized: "handlers.failed.hardReloadEngine", defaultValue: "This browser engine cannot bypass the cache; use Reload Page.", table: "Handlers", bundle: .module) }
    static var noUnread: String { String(localized: "handlers.failed.noUnread", defaultValue: "There are no unread notifications.", table: "Handlers", bundle: .module) }
    static var markUnread: String { String(localized: "handlers.failed.markUnread", defaultValue: "The daemon cannot mark a notification unread.", table: "Handlers", bundle: .module) }
    static var noAgentSession: String { String(localized: "handlers.failed.noAgentSession", defaultValue: "The focused terminal has no agent session to fork.", table: "Handlers", bundle: .module) }
    static var forkClaudeOnly: String { String(localized: "handlers.failed.forkClaudeOnly", defaultValue: "Forking is supported for Claude sessions only.", table: "Handlers", bundle: .module) }
    static var notificationAck: String { String(localized: "handlers.failed.notificationAck", defaultValue: "The connected cmux-tui daemon does not support notification acknowledgement (notification-ack-v1).", table: "Handlers", bundle: .module) }
    static var noFile: String { String(localized: "handlers.failed.noFile", defaultValue: "No file is focused.", table: "Handlers", bundle: .module) }
    static func appNotFound(_ app: String) -> String {
        String(format: String(localized: "handlers.failed.appNotFound", defaultValue: "No app named %@ was found.", table: "Handlers", bundle: .module), app)
    }
}
