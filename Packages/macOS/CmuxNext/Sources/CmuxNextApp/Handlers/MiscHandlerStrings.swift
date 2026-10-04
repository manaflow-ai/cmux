import Foundation

/// User-facing reasons for typed "unavailable" and "failed" action
/// results. Keys live in Resources/MiscHandlers.xcstrings (en, ja).
enum MiscHandlerStrings {
    static var untitledTab: String { String(localized: "handlers.misc.closed.untitledTab", defaultValue: "Untitled Tab", table: "MiscHandlers", bundle: .module) }
    static var untitledScreen: String { String(localized: "handlers.misc.closed.untitledScreen", defaultValue: "Untitled Screen", table: "MiscHandlers", bundle: .module) }
    static var untitledWorkspace: String { String(localized: "handlers.misc.closed.untitledWorkspace", defaultValue: "Untitled Workspace", table: "MiscHandlers", bundle: .module) }
    static var cloud: String { String(localized: "handlers.misc.unavailable.cloud", defaultValue: "Cloud actions arrive with the Cloud wave; cmux-next has no Cloud client yet.", table: "MiscHandlers", bundle: .module) }
    static var diffViewer: String { String(localized: "handlers.misc.unavailable.diffViewer", defaultValue: "cmux-next has no diff viewer yet.", table: "MiscHandlers", bundle: .module) }
    static var markdownViewer: String { String(localized: "handlers.misc.unavailable.markdownViewer", defaultValue: "cmux-next has no Markdown viewer yet.", table: "MiscHandlers", bundle: .module) }
    static var filePreview: String { String(localized: "handlers.misc.unavailable.filePreview", defaultValue: "cmux-next has no file preview surface yet.", table: "MiscHandlers", bundle: .module) }
    static var vscodeServer: String { String(localized: "handlers.misc.unavailable.vscodeServer", defaultValue: "The inline VS Code server is not ported to cmux-next yet.", table: "MiscHandlers", bundle: .module) }
    static var reactGrab: String { String(localized: "handlers.misc.unavailable.reactGrab", defaultValue: "React Grab injection is not ported yet.", table: "MiscHandlers", bundle: .module) }
    static var omnibarToggle: String { String(localized: "handlers.misc.unavailable.omnibarToggle", defaultValue: "The address bar cannot be hidden yet.", table: "MiscHandlers", bundle: .module) }
    static var browserHistory: String { String(localized: "handlers.misc.unavailable.browserHistory", defaultValue: "cmux-next keeps no browser history store yet.", table: "MiscHandlers", bundle: .module) }
    static var browserToggle: String { String(localized: "handlers.misc.unavailable.browserToggle", defaultValue: "The cmux browser is always on in cmux-next; there is no setting to turn it off yet.", table: "MiscHandlers", bundle: .module) }
    static var linkTarget: String { String(localized: "handlers.misc.unavailable.linkTarget", defaultValue: "Link context menus do not pass a link to actions yet.", table: "MiscHandlers", bundle: .module) }
    static var sectionScreenshot: String { String(localized: "handlers.misc.unavailable.sectionScreenshot", defaultValue: "Section screenshots need a selection overlay that is not built yet.", table: "MiscHandlers", bundle: .module) }
    static var agentChat: String { String(localized: "handlers.misc.unavailable.agentChat", defaultValue: "Agent chat views are not ported to cmux-next yet.", table: "MiscHandlers", bundle: .module) }
    static var agentTeams: String { String(localized: "handlers.misc.unavailable.agentTeams", defaultValue: "The Claude and Codex Teams launcher is not ported to cmux-next yet.", table: "MiscHandlers", bundle: .module) }
    static var computerUse: String { String(localized: "handlers.misc.unavailable.computerUse", defaultValue: "Computer Use integration is not ported to cmux-next yet.", table: "MiscHandlers", bundle: .module) }
    static var noBrowser: String { String(localized: "handlers.misc.failed.noBrowser", defaultValue: "No browser tab is focused.", table: "MiscHandlers", bundle: .module) }
    static var noTerminal: String { String(localized: "handlers.misc.failed.noTerminal", defaultValue: "No terminal tab is focused.", table: "MiscHandlers", bundle: .module) }
    /// A shortcut the key window's kind does not support (`WindowKeyTable`).
    static var notInThisWindow: String { String(localized: "handlers.misc.unavailable.windowKind", defaultValue: "Not available in this window.", table: "MiscHandlers", bundle: .module) }
    static var noPane: String { String(localized: "handlers.misc.failed.noPane", defaultValue: "No pane is focused.", table: "MiscHandlers", bundle: .module) }
    static var daemonOffline: String { String(localized: "handlers.misc.failed.daemonOffline", defaultValue: "The cmux-tui daemon is not connected.", table: "MiscHandlers", bundle: .module) }
    static var noPageURL: String { String(localized: "handlers.misc.failed.noPageURL", defaultValue: "The page has no URL.", table: "MiscHandlers", bundle: .module) }
    static var hardReloadEngine: String { String(localized: "handlers.misc.failed.hardReloadEngine", defaultValue: "This browser engine cannot bypass the cache; use Reload Page.", table: "MiscHandlers", bundle: .module) }
    static var noUnread: String { String(localized: "handlers.misc.failed.noUnread", defaultValue: "There are no unread notifications.", table: "MiscHandlers", bundle: .module) }
    static var markUnread: String { String(localized: "handlers.misc.failed.markUnread", defaultValue: "The daemon cannot mark a notification unread.", table: "MiscHandlers", bundle: .module) }
    static var noAgentSession: String { String(localized: "handlers.misc.failed.noAgentSession", defaultValue: "The focused terminal has no agent session to fork.", table: "MiscHandlers", bundle: .module) }
    static var forkClaudeOnly: String { String(localized: "handlers.misc.failed.forkClaudeOnly", defaultValue: "Forking is supported for Claude sessions only.", table: "MiscHandlers", bundle: .module) }
    static var noAgentChat: String { String(localized: "handlers.misc.failed.noAgentChat", defaultValue: "Dictation works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var continueInNeedsFocus: String { String(localized: "handlers.misc.failed.continueInNeedsFocus", defaultValue: "Continue in… requires focus; use cmux acp continue for a headless handoff.", table: "MiscHandlers", bundle: .module) }
    static var quickChatNeedsFocus: String { String(localized: "handlers.misc.failed.quickChatNeedsFocus", defaultValue: "Quick Agent Chat opens from the keyboard, palette or menu. It does not take the keyboard for automation.", table: "MiscHandlers", bundle: .module) }
    static var quickChatUnavailable: String { String(localized: "handlers.misc.failed.quickChatUnavailable", defaultValue: "Quick Agent Chat needs the agent page, which this build does not include.", table: "MiscHandlers", bundle: .module) }
    static var checkpointNeedsFocus: String { String(localized: "handlers.misc.failed.checkpointNeedsFocus", defaultValue: "Checkpoint review requires focus. Use git.checkpoint.create for a headless capture.", table: "MiscHandlers", bundle: .module) }
    static var noFile: String { String(localized: "handlers.misc.failed.noFile", defaultValue: "No file is focused.", table: "MiscHandlers", bundle: .module) }
    static var agentChromiumPage: String { String(localized: "handlers.misc.failed.agentChromiumPage", defaultValue: "Automation cannot open Chromium's own pages (chrome://, chrome-extension://, devtools://).", table: "MiscHandlers", bundle: .module) }
    static func invalidURL(_ text: String) -> String {
        String(format: String(localized: "handlers.misc.failed.invalidURL", defaultValue: "%@ is not a URL cmux can open.", table: "MiscHandlers", bundle: .module), text)
    }
    static func fileNotFound(_ path: String) -> String {
        String(format: String(localized: "handlers.misc.failed.fileNotFound", defaultValue: "%@ is not a file cmux can open.", table: "MiscHandlers", bundle: .module), path)
    }
    static func fileNotInTab(_ path: String) -> String {
        String(format: String(localized: "handlers.misc.failed.fileNotInTab", defaultValue: "%@ opens in the editor, not in a tab.", table: "MiscHandlers", bundle: .module), path)
    }
    static func pathNotAbsolute(_ path: String) -> String {
        String(format: String(localized: "handlers.misc.failed.pathNotAbsolute", defaultValue: "%@ is a relative path. Give the file's absolute path.", table: "MiscHandlers", bundle: .module), path)
    }
    static func invalidPlace(_ place: String) -> String {
        String(format: String(localized: "handlers.misc.failed.invalidPlace", defaultValue: "%@ is not a place to open a file. Use tab or editor.", table: "MiscHandlers", bundle: .module), place)
    }
    static var noEditor: String { String(localized: "handlers.misc.failed.noEditor", defaultValue: "No app on this Mac edits text.", table: "MiscHandlers", bundle: .module) }
    static func appNotFound(_ app: String) -> String {
        String(format: String(localized: "handlers.misc.failed.appNotFound", defaultValue: "No app named %@ was found.", table: "MiscHandlers", bundle: .module), app)
    }
}
