import Foundation

/// Move to Cloud's text (``CloudMove``). Keys live in Resources/Cloud.xcstrings.
enum CloudMoveStrings {
    static var moving: String {
        String(localized: "cloud.move.moving", defaultValue: "Moving this chat to Cloud…", table: "Cloud", bundle: .module)
    }
    static func moved(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.moved", defaultValue: "This chat now runs on %@.", table: "Cloud", bundle: .module), machine)
    }
    static var retry: String { String(localized: "cloud.move.retry", defaultValue: "Retry", table: "Cloud", bundle: .module) }
    static var notAChat: String {
        String(localized: "cloud.move.notAChat", defaultValue: "Move to Cloud works on a chat tab.", table: "Cloud", bundle: .module)
    }
    static var alreadyRemote: String {
        String(localized: "cloud.move.alreadyRemote", defaultValue: "This chat already runs on another machine.", table: "Cloud", bundle: .module)
    }
    static var noSession: String {
        String(localized: "cloud.move.noSession", defaultValue: "Send a first message, then move this chat.", table: "Cloud", bundle: .module)
    }
    static var noFolder: String {
        String(localized: "cloud.move.noFolder", defaultValue: "This chat has no folder to copy to the machine.", table: "Cloud", bundle: .module)
    }
    static var homeFolder: String {
        String(localized: "cloud.move.homeFolder", defaultValue: "Move to Cloud copies a project folder, never your home folder. Start the chat in a project folder first.",
               table: "Cloud", bundle: .module)
    }
    static func relativePath(_ path: String) -> String {
        String(format: String(localized: "cloud.move.relativePath", defaultValue: "Move to Cloud needs a full folder path, not %@.", table: "Cloud", bundle: .module),
               path)
    }
    static func noSuchMachine(_ id: String) -> String {
        String(format: String(localized: "cloud.move.noSuchMachine", defaultValue: "No Cloud machine has the id %@.", table: "Cloud", bundle: .module), id)
    }
    static func linkUnsupported(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.linkUnsupported", defaultValue: "%@ can't take a chat over its current connection. Pick another machine.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func notConnected(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.notConnected", defaultValue: "%@ didn't connect. Retry once it's online.", table: "Cloud", bundle: .module), machine)
    }
    static func syncFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.syncFailed", defaultValue: "Couldn't copy the folder to %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
    static var unresolved: String {
        String(localized: "cloud.move.unresolved", defaultValue: "The move didn't finish, so the chat is paused. Retry to finish it.", table: "Cloud", bundle: .module)
    }
    /// After a relaunch: the chat's move stopped before the chat moved (cx-rppd.16).
    static var unfinishedMove: String {
        String(localized: "cloud.move.unfinishedMove", defaultValue: "Moving this chat to Cloud didn't finish. Retry to finish it, or dismiss to keep it here.",
               table: "Cloud", bundle: .module)
    }
    /// After a relaunch: the chat moved, but its tab on the machine never opened (cx-rppd.16).
    static var unfinishedShow: String {
        String(localized: "cloud.move.unfinishedShow", defaultValue: "This chat moved to Cloud, but its tab there didn't open. Retry to open it.",
               table: "Cloud", bundle: .module)
    }
    static var inProgress: String {
        String(localized: "cloud.move.inProgress", defaultValue: "This chat is already moving. Retry in a moment.", table: "Cloud", bundle: .module)
    }
    static func teamMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.teamMachine", defaultValue: "%@ is a team machine. Chats move only to a machine you own.",
                              table: "Cloud", bundle: .module), machine)
    }
    /// The machine's cmux-tui is too old for the move (`machine_outdated`, cx-rppd.13).
    static func outdatedMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.outdatedMachine", defaultValue: "%@ runs an older cmux that can't take this chat yet. Update the machine to move it.",
                              table: "Cloud", bundle: .module), machine)
    }
    /// What a link CLI answers when the machine's cmux-tui is too old for it (cmux-tui `link/machine_gate.rs`).
    static let outdatedCode = "machine_outdated"
    static func unknownMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unknownMachine", defaultValue: "cmux can't confirm who owns %@, so the chat stays on this Mac.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func unreachable(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unreachable", defaultValue: "Lost the connection to %@ during the move. Retry to finish it.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func moveFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.move.failed", defaultValue: "Couldn't move the chat. Try again; if it keeps failing, run `cmux cloud diagnostics`. Reason: %@", table: "Cloud", bundle: .module), detail)
    }
    static func tabFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.tabFailed", defaultValue: "The chat moved to %1$@, but its tab didn't open: %2$@",
                              table: "Cloud", bundle: .module), machine, detail)
    }
}
