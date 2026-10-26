import Foundation

/// User-facing reasons for typed "unavailable" and "failed" action
/// results. Keys live in Resources/MiscHandlers.xcstrings (en, ja).
enum MiscHandlerStrings {
    /// The undo toast of a closed tab (REOPEN-CLOSED): `Closed “<title>”`.
    static func tabClosed(_ title: String) -> String {
        String(format: String(localized: "handlers.misc.closed.toast", defaultValue: "Closed “%@”", table: "MiscHandlers", bundle: .module), title)
    }
    /// The undo toast of a group close (REOPEN-CLOSED): `Closed N tabs` (plural rules).
    static func tabsClosed(_ count: Int) -> String {
        String(localized: "handlers.misc.closed.toastTabs", defaultValue: "Closed \(count) tabs", table: "MiscHandlers", bundle: .module)
    }
    static var untitledTab: String { String(localized: "handlers.misc.closed.untitledTab", defaultValue: "Untitled Tab", table: "MiscHandlers", bundle: .module) }
    static var untitledScreen: String { String(localized: "handlers.misc.closed.untitledScreen", defaultValue: "Untitled Screen", table: "MiscHandlers", bundle: .module) }
    static var untitledWorkspace: String { String(localized: "handlers.misc.closed.untitledWorkspace", defaultValue: "Untitled Workspace", table: "MiscHandlers", bundle: .module) }
    static var cloud: String { String(localized: "handlers.misc.unavailable.cloud", defaultValue: "This version of cmux can't run this Cloud action. Update cmux, then try again.", table: "MiscHandlers", bundle: .module) }
    static var reactGrabFailed: String { String(localized: "handlers.misc.reactGrabFailed", defaultValue: "React Grab could not load on this page.", table: "MiscHandlers", bundle: .module) }
    /// A browser tab refused while `browser.enabled` is off.
    static var browserOff: String { String(localized: "handlers.misc.browserOff", defaultValue: "The cmux browser is off. Run Enable cmux Browser to open web pages in cmux.", table: "MiscHandlers", bundle: .module) }
    static var defaultBrowserIsCmux: String {
        String(localized: "handlers.misc.defaultBrowserIsCmux", defaultValue: "cmux is the default browser, so the link opens in cmux", table: "MiscHandlers", bundle: .module)
    }
    static var noDefaultBrowser: String { String(localized: "handlers.misc.noDefaultBrowser", defaultValue: "No app opens this link", table: "MiscHandlers", bundle: .module) }
    static var terminalChatNoSession: String { String(localized: "handlers.misc.failed.terminalChatNoSession", defaultValue: "The focused terminal runs no agent session to open as a chat.", table: "MiscHandlers", bundle: .module) }
    static var terminalChatHarness: String { String(localized: "handlers.misc.failed.terminalChatHarness", defaultValue: "Only Claude Code and Codex sessions can open as a chat.", table: "MiscHandlers", bundle: .module) }
    /// A Simulator shortcut (Home, Rotate, Appearance, Software Keyboard) with no phone tab focused.
    static var noPhoneTab: String { String(localized: "handlers.misc.failed.noPhoneTab", defaultValue: "No phone tab is focused.", table: "MiscHandlers", bundle: .module) }
    static var noBrowser: String { String(localized: "handlers.misc.failed.noBrowser", defaultValue: "No browser tab is focused.", table: "MiscHandlers", bundle: .module) }
    static var noTerminal: String { String(localized: "handlers.misc.failed.noTerminal", defaultValue: "No terminal tab is focused.", table: "MiscHandlers", bundle: .module) }
    /// A shortcut the key window's kind does not support (`WindowKeyTable`).
    static var notInThisWindow: String { String(localized: "handlers.misc.unavailable.windowKind", defaultValue: "Not available in this window.", table: "MiscHandlers", bundle: .module) }
    static var noPane: String { String(localized: "handlers.misc.failed.noPane", defaultValue: "No pane is focused.", table: "MiscHandlers", bundle: .module) }
    /// The sheet that asks for a terminal's resume command (Set/Edit Resume Command).
    static var daemonOffline: String { String(localized: "handlers.misc.failed.daemonOffline", defaultValue: "The cmux-tui daemon is not connected.", table: "MiscHandlers", bundle: .module) }
    static var printUnavailable: String { String(localized: "handlers.misc.failed.printUnavailable", defaultValue: "This page can't be printed now.", table: "MiscHandlers", bundle: .module) }
    static var noPageURL: String { String(localized: "handlers.misc.failed.noPageURL", defaultValue: "The page has no URL.", table: "MiscHandlers", bundle: .module) }
    static var hardReloadEngine: String { String(localized: "handlers.misc.failed.hardReloadEngine", defaultValue: "This browser engine cannot bypass the cache; use Reload Page.", table: "MiscHandlers", bundle: .module) }
    static var noUnread: String { String(localized: "handlers.misc.failed.noUnread", defaultValue: "There are no unread notifications.", table: "MiscHandlers", bundle: .module) }
    static var noNotificationToCopy: String {
        String(localized: "handlers.misc.failed.noNotificationToCopy", defaultValue: "There are no notifications to copy.", table: "MiscHandlers", bundle: .module)
    }
    static var noPrompt: String { String(localized: "handlers.misc.failed.noPrompt", defaultValue: "No agent has been given a prompt yet.", table: "MiscHandlers", bundle: .module) }
    /// `agent.openSessionTab` with a peer `host` this Mac mirrors, but no live chat of it named `session`.
    static func noPeerSession(_ session: String, _ peer: String) -> String {
        String(format: String(localized: "handlers.misc.failed.noPeerSession", defaultValue: "%1$@ has no running chat named %2$@.", table: "MiscHandlers", bundle: .module), peer, session)
    }
    /// `agent.openSessionTab` with a peer `host` where more than one live chat has the name `session`.
    static func ambiguousPeerSession(_ session: String, _ peer: String) -> String {
        String(format: String(localized: "handlers.misc.failed.ambiguousPeerSession", defaultValue: "%1$@ has more than one chat named %2$@. Name it by its session id.", table: "MiscHandlers", bundle: .module), peer, session)
    }
    static var sessionRequired: String { String(localized: "handlers.misc.failed.sessionRequired", defaultValue: "Name the acpmux session to open (session).", table: "MiscHandlers", bundle: .module) }
    static var noAgentSession: String { String(localized: "handlers.misc.failed.noAgentSession", defaultValue: "The focused terminal has no agent session to fork.", table: "MiscHandlers", bundle: .module) }
    static var noAgentPane: String { String(localized: "handlers.misc.failed.noAgentPane", defaultValue: "The focused pane is not showing an agent chat.", table: "MiscHandlers", bundle: .module) }
    static var forkTerminalAgents: String { String(localized: "handlers.misc.failed.forkTerminalAgents", defaultValue: "A terminal agent forks with Claude Code or Codex only. Open it as a chat to fork it.", table: "MiscHandlers", bundle: .module) }
    static var noForkTarget: String { String(localized: "handlers.misc.failed.noForkTarget", defaultValue: "Focus an agent chat, or a terminal running Claude Code or Codex, to fork it.", table: "MiscHandlers", bundle: .module) }
    static var gitNeedsAgentChat: String { String(localized: "handlers.misc.failed.gitNeedsAgentChat", defaultValue: "Commit and Push work in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var noAgentChat: String { String(localized: "handlers.misc.failed.noAgentChat", defaultValue: "Dictation works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var switchModelNeedsFocus: String { String(localized: "handlers.misc.failed.switchModelNeedsFocus", defaultValue: "Switch Model… opens a menu, so it needs focus.", table: "MiscHandlers", bundle: .module) }
    static var switchModelNeedsAgentChat: String { String(localized: "handlers.misc.failed.switchModelNeedsAgentChat", defaultValue: "Switch Model… works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var copyCodeNeedsAgentChat: String { String(localized: "handlers.misc.failed.copyCodeNeedsAgentChat", defaultValue: "Copy Last Code Block works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var noCodeBlock: String { String(localized: "handlers.misc.failed.noCodeBlock", defaultValue: "This chat has no code block to copy.", table: "MiscHandlers", bundle: .module) }
    static var copyCodeFailed: String { String(localized: "handlers.misc.failed.copyCodeFailed", defaultValue: "The last code block could not be copied.", table: "MiscHandlers", bundle: .module) }
    static var noWorkingChief: String { String(localized: "handlers.misc.failed.noWorkingChief", defaultValue: "No Chief is working right now.", table: "MiscHandlers", bundle: .module) }
    static var noChief: String { String(localized: "handlers.misc.failed.noChief", defaultValue: "There is no Chief yet. Make one with New Chief.", table: "MiscHandlers", bundle: .module) }
    static var homeChiefPaneStays: String { String(localized: "handlers.misc.failed.homeChiefPaneStays", defaultValue: "The Chief pane stays open in Home.", table: "MiscHandlers", bundle: .module) }
    static var channelsCannotStep: String { String(localized: "handlers.misc.failed.channelsCannotStep", defaultValue: "Channels did not move to another conversation.", table: "MiscHandlers", bundle: .module) }
    static var archiveChatNeedsAgentChat: String { String(localized: "handlers.misc.failed.archiveChatNeedsAgentChat", defaultValue: "Archive Chat works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var searchFilesNeedsAgentChat: String { String(localized: "handlers.misc.failed.searchFilesNeedsAgentChat", defaultValue: "Search Files… works in agent chats. Focus one first.", table: "MiscHandlers", bundle: .module) }
    static var continueInNeedsFocus: String { String(localized: "handlers.misc.failed.continueInNeedsFocus", defaultValue: "Continue In… requires focus; use cmux acp continue for a headless handoff.", table: "MiscHandlers", bundle: .module) }
    static var quickChatNeedsFocus: String { String(localized: "handlers.misc.failed.quickChatNeedsFocus", defaultValue: "Start Agent opens from the keyboard, palette or menu. It does not take the keyboard for automation.", table: "MiscHandlers", bundle: .module) }
    static var quickChatUnavailable: String { String(localized: "handlers.misc.failed.quickChatUnavailable", defaultValue: "Start Agent needs the agent page, which this build does not include.", table: "MiscHandlers", bundle: .module) }
    static var checkpointNeedsFocus: String { String(localized: "handlers.misc.failed.checkpointNeedsFocus", defaultValue: "Checkpoint review requires focus. Use git.checkpoint.create for a headless capture.", table: "MiscHandlers", bundle: .module) }
    static var gitWriteNeedsFocus: String { String(localized: "handlers.misc.failed.gitWriteNeedsFocus", defaultValue: "Commit and push from the agent pane require focus. Use cmux git commit or cmux git push to run them headless.", table: "MiscHandlers", bundle: .module) }
    static var noFile: String { String(localized: "handlers.misc.failed.noFile", defaultValue: "No file is focused.", table: "MiscHandlers", bundle: .module) }
    static var agentChromiumPage: String { String(localized: "handlers.misc.failed.agentChromiumPage", defaultValue: "Automation cannot open Chromium's own pages (chrome://, chrome-extension://, devtools://).", table: "MiscHandlers", bundle: .module) }
    static func unknownBrowserProfile(_ text: String) -> String {
        String(format: String(localized: "handlers.misc.failed.unknownBrowserProfile",
                              defaultValue: "%@ is not a browser profile. Use \"agent\" or the id of an existing profile.",
                              table: "MiscHandlers", bundle: .module), text)
    }
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
    /// A cmux picker asked for by a run that may not change the view (an agent, the CLI without
    /// focus): it would open over the person's window.
    static var pickerNeedsFocus: String {
        String(localized: "handlers.misc.refusal.pickerNeedsFocus", defaultValue: "The picker opens only when focus is requested.",
               table: "MiscHandlers", bundle: .module)
    }
    static var noEditor: String { String(localized: "handlers.misc.failed.noEditor", defaultValue: "No app on this Mac edits text.", table: "MiscHandlers", bundle: .module) }
    static func appNotFound(_ app: String) -> String {
        String(format: String(localized: "handlers.misc.failed.appNotFound", defaultValue: "No app named %@ was found.", table: "MiscHandlers", bundle: .module), app)
    }
}
