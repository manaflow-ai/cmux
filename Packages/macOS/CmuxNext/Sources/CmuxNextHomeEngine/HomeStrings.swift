import Foundation

/// Home strings (Resources/Home.xcstrings).
public nonisolated enum HomeStrings {
    public static var title: String { String(localized: "home.title", defaultValue: "Home", table: "Home", bundle: .module) }
    /// The chief's name (N1): the chief conversation's title and the mux's name.
    public static var chiefName: String { String(localized: "home.chief.name", defaultValue: "Chief", table: "Home", bundle: .module) }
    /// Chief's first message on a fresh install: its greeting (``ChiefWelcome``).
    static var chiefWelcomeHello: String {
        String(localized: "home.chief.welcomeHello", defaultValue: "Welcome to cmux! 👋 I'm Chief.", table: "Home", bundle: .module)
    }
    /// Chief's second message on a fresh install: what it can do (``ChiefWelcome``).
    static var chiefWelcomeAbout: String {
        String(localized: "home.chief.welcomeAbout",
               defaultValue: "I can make new workspaces, start agents for you, and set up or customize cmux however you like.\nJust tell me what you want done.",
               table: "Home", bundle: .module)
    }
    /// Chief's third message on a fresh install: the background offer, with the picker's `link`.
    static func chiefWelcomeBackground(link: String) -> String {
        String(format: String(localized: "home.chief.welcomeBackground",
                              defaultValue: "Want to make it yours? [Pick a background](%@) from the built-in art or one of your own pictures. Or skip it and just say hi.",
                              table: "Home", bundle: .module), link)
    }
    public static var unavailable: String {
        String(localized: "home.unavailable", defaultValue: "Conversations need a newer cmux daemon.", table: "Home", bundle: .module)
    }
    public static var newConversationTitle: String {
        String(localized: "home.newConversation.title", defaultValue: "New Conversation", table: "Home", bundle: .module)
    }
    /// Home's notice while an older build's own Chief still runs.
    static var chiefMergeBlocked: String {
        String(localized: "home.chief.mergeBlocked", defaultValue: "Quit older cmux DEV builds to merge Chief history", table: "Home", bundle: .module)
    }
    /// The Chief's notice while agents are off in this build session (cx-tgf4h).
    public static var chiefAgentsDisabled: String {
        String(localized: "home.chief.agentsDisabled",
               defaultValue: "Agents are disabled in this build session. The Chief does not answer.",
               table: "Home", bundle: .module)
    }
    /// The Chief conversation's system notice while the compactor cannot build summaries (cx-oqnw3).
    static var chiefMemoryPaused: String {
        String(localized: "home.chief.memoryPaused", defaultValue: "Chief memory summaries are paused. The Chief still answers.",
               table: "Home", bundle: .module)
    }
    /// The Chief conversation's notice while the person's last message has had no reply
    /// for `minutes` (ChiefReplyWatchdog; at least 2).
    static func chiefNoReply(minutes: Int) -> String {
        String(format: String(localized: "home.chief.noReply",
                              defaultValue: "No reply from the Chief for %lld min. It retries on its own and tells you if it cannot answer.",
                              table: "Home", bundle: .module), minutes)
    }
    /// The Chief conversation's notice while a turn waits for the compactor.
    static func chiefOrganizing(built: Int, total: Int) -> String {
        String(format: String(localized: "home.chief.organizing", defaultValue: "Organizing Chief history: %1$lld of %2$lld",
                              table: "Home", bundle: .module), built, total)
    }
    public static var archiveDefaultChief: String {
        String(localized: "home.chief.archive.default", defaultValue: "Make another Chief the default before archiving this one.",
               table: "Home", bundle: .module)
    }
    public static var archiveFailed: String {
        String(localized: "home.chief.archive.failed", defaultValue: "The Chief couldn’t be archived. Try again.", table: "Home",
               bundle: .module)
    }
    public static var deleteDefaultChief: String {
        String(localized: "home.chief.delete.default", defaultValue: "Make another Chief the default before deleting this one.",
               table: "Home", bundle: .module)
    }
    public static var deleteFailed: String {
        String(localized: "home.chief.delete.failed", defaultValue: "The Chief couldn’t be deleted. Try again.", table: "Home",
               bundle: .module)
    }
    /// Delete Chief's question: its title names the Chief.
    public static func deleteChiefTitle(_ name: String) -> String {
        String(format: String(localized: "home.chief.delete.title", defaultValue: "Delete “%@”?", table: "Home", bundle: .module), name)
    }
    public static var deleteChiefBody: String {
        String(localized: "home.chief.delete.body",
               defaultValue: "The Chief stops and is removed for good, and its conversation leaves the list. You can’t undo this. Archive Chief hides a Chief instead.",
               table: "Home", bundle: .module)
    }
    public static var deleteChiefButton: String {
        String(localized: "home.chief.delete.button", defaultValue: "Delete Chief", table: "Home", bundle: .module)
    }
    /// The welcome's call-out of Go to Workspace; the argument is its shortcut (`⌘P`).
    static func chiefWelcomeGoTo(_ keys: String) -> String {
        String(format: String(localized: "home.chief.welcome.goTo",
                              defaultValue: "**Press `%@` to go anywhere.** It jumps to any open workspace, tab or agent, so it's the first shortcut to learn.",
                              table: "Home", bundle: .module), keys)
    }
    /// The heading over the welcome's other shortcuts.
    static var chiefWelcomeShortcuts: String {
        String(localized: "home.chief.welcome.shortcuts", defaultValue: "More shortcuts:", table: "Home", bundle: .module)
    }
    /// The heading over the welcome's example requests.
    static var chiefWelcomeExamplesHeader: String {
        String(localized: "home.chief.welcome.examplesHeader", defaultValue: "Things you can ask me:", table: "Home", bundle: .module)
    }
    /// The welcome's example requests, one Markdown list item per line.
    static var chiefWelcomeExamples: String {
        String(localized: "home.chief.welcome.examples",
               defaultValue: "- Start a Claude Code agent to fix the failing tests in my repo\n- What are my agents working on right now?\n- Open localhost:3000 in a browser and tell me what's broken\n- Run three Codex agents on these issues, each in its own workspace",
               table: "Home", bundle: .module)
    }
    /// The welcome's last line: what the Chief answers.
    static var chiefWelcomeAsk: String {
        String(localized: "home.chief.welcome.ask",
               defaultValue: "Ask me anything about cmux: how a feature works, managing your coding agents, or your browsers. Type below to start.",
               table: "Home", bundle: .module)
    }
}
