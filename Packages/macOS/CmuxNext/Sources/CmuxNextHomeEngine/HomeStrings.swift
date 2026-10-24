import Foundation

/// Home strings (Resources/Home.xcstrings).
public nonisolated enum HomeStrings {
    public static var title: String { String(localized: "home.title", defaultValue: "Home", table: "Home", bundle: .module) }
    /// The chief's name (N1): the chief conversation's title and the mux's name.
    public static var chiefName: String { String(localized: "home.chief.name", defaultValue: "Chief", table: "Home", bundle: .module) }
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
}
