public import CmuxNextCloud
import Foundation

/// Move to Cloud's text (the App's `CloudMove`, `CloudStartChat`, `CloudBringBack`). Keys live in
/// Resources/Cloud.xcstrings with every app locale.
public struct CloudMoveStrings {
    public init() {}
    public static var moving: String {
        String(localized: "cloud.move.moving", defaultValue: "Moving this chat to Cloud…", table: "Cloud", bundle: .module)
    }
    public static func moved(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.moved", defaultValue: "This chat now runs on %@.", table: "Cloud", bundle: .module), machine)
    }
    public static var retry: String { String(localized: "cloud.move.retry", defaultValue: "Retry", table: "Cloud", bundle: .module) }
    public static var notAChat: String {
        String(localized: "cloud.move.notAChat", defaultValue: "Move to Cloud works on a chat tab.", table: "Cloud", bundle: .module)
    }
    public static var alreadyRemote: String {
        String(localized: "cloud.move.alreadyRemote", defaultValue: "This chat already runs on another machine.", table: "Cloud", bundle: .module)
    }
    public static var noSession: String {
        String(localized: "cloud.move.noSession", defaultValue: "Send a first message, then move this chat.", table: "Cloud", bundle: .module)
    }
    public static var noFolder: String {
        String(localized: "cloud.move.noFolder", defaultValue: "This chat has no folder to copy to the machine.", table: "Cloud", bundle: .module)
    }
    public static var homeFolder: String {
        String(localized: "cloud.move.homeFolder", defaultValue: "Move to Cloud copies a project folder, never your home folder. Start the chat in a project folder first.",
               table: "Cloud", bundle: .module)
    }
    /// `cloud.startChat`: the account or team changed while the send started (``CloudStartChat/checkAccount(_:now:listCurrent:)``).
    public static var startChatAccountChanged: String {
        String(localized: "cloud.startChat.accountChanged",
               defaultValue: "Your Cloud account or team changed while this chat was starting, so nothing was copied. Send it again in the account you want it in.",
               table: "Cloud", bundle: .module)
    }
    /// `cloud.startChat`: the machine list of the account signed in now could not be read.
    public static var startChatListUnread: String {
        String(localized: "cloud.startChat.listUnread",
               defaultValue: "Couldn't read the Cloud machines of the account signed in now, so this chat stays on this Mac. Try again in a moment.",
               table: "Cloud", bundle: .module)
    }
    public static func relativePath(_ path: String) -> String {
        String(format: String(localized: "cloud.move.relativePath", defaultValue: "Move to Cloud needs a full folder path, not %@.", table: "Cloud", bundle: .module),
               path)
    }
    /// A move's or bring back's machine is gone from the person's machines: the chat can't reach it again.
    public static var machineDeleted: String {
        String(localized: "cloud.move.machineDeleted", defaultValue: "This chat's Cloud machine was deleted.", table: "Cloud", bundle: .module)
    }
    public static func noSuchMachine(_ id: String) -> String {
        String(format: String(localized: "cloud.move.noSuchMachine", defaultValue: "No Cloud machine has the id %@.", table: "Cloud", bundle: .module), id)
    }
    public static func notConnected(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.notConnected", defaultValue: "%@ didn't connect. Retry once it's online.", table: "Cloud", bundle: .module), machine)
    }
    /// A legacy link start that stopped at `step` with `reason` (``CloudLinkStartError``).
    public static func notConnected(_ machine: String, step: CloudLinkStep, reason: String) -> String {
        String(format: String(localized: "cloud.move.notConnectedAtStep", defaultValue: "%1$@ didn't connect: %2$@ failed (%3$@).", table: "Cloud", bundle: .module),
               machine, linkStep(step), reason)
    }
    public static func linkStep(_ step: CloudLinkStep) -> String {
        switch step {
        case .attachEndpoint: String(localized: "cloud.move.linkStep.attachEndpoint", defaultValue: "Asking cmux Cloud for the machine's address", table: "Cloud", bundle: .module)
        case .hub: String(localized: "cloud.move.linkStep.hub", defaultValue: "Starting this Mac's tunnel to cmux Cloud", table: "Cloud", bundle: .module)
        case .approve: String(localized: "cloud.move.linkStep.approve", defaultValue: "Approving this Mac on the machine", table: "Cloud", bundle: .module)
        case .remoteConnect: String(localized: "cloud.move.linkStep.remoteConnect", defaultValue: "Opening the link to the machine", table: "Cloud", bundle: .module)
        }
    }
    public static func syncFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.syncFailed", defaultValue: "Couldn't copy the folder to %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
    public static var unresolved: String {
        String(localized: "cloud.move.unresolved", defaultValue: "The move didn't finish, so the chat is paused. Retry to finish it.", table: "Cloud", bundle: .module)
    }
    /// After a relaunch: the chat's move stopped before the chat moved (cx-rppd.16).
    public static var unfinishedMove: String {
        String(localized: "cloud.move.unfinishedMove", defaultValue: "Moving this chat to Cloud didn't finish. Retry to finish it, or dismiss to keep it here.",
               table: "Cloud", bundle: .module)
    }
    /// After a relaunch: the chat moved, but its tab on the machine never opened (cx-rppd.16).
    public static var unfinishedShow: String {
        String(localized: "cloud.move.unfinishedShow", defaultValue: "This chat moved to Cloud, but its tab there didn't open. Retry to open it.",
               table: "Cloud", bundle: .module)
    }
    public static var inProgress: String {
        String(localized: "cloud.move.inProgress", defaultValue: "This chat is already moving. Retry in a moment.", table: "Cloud", bundle: .module)
    }
    public static func teamMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.teamMachine", defaultValue: "%@ is a team machine. Chats move only to a machine you own.",
                              table: "Cloud", bundle: .module), machine)
    }
    /// The machine's cmux-tui is too old for the move (`machine_outdated`, cx-rppd.13).
    public static func outdatedMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.outdatedMachine", defaultValue: "%@ runs an older cmux that can't take this chat yet. Update the machine to move it.",
                              table: "Cloud", bundle: .module), machine)
    }
    /// What a link CLI answers when the machine's cmux-tui is too old for it (cmux-tui `link/machine_gate.rs`).
    public static let outdatedCode = CloudOutdatedMachine.code
    public static func unknownMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unknownMachine", defaultValue: "cmux can't confirm who owns %@, so the chat stays on this Mac.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static func unreachable(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unreachable", defaultValue: "Lost the connection to %@ during the move. Retry to finish it.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static func moveFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.move.failed", defaultValue: "Couldn't move the chat. Try again; if it keeps failing, run `cmux cloud diagnostics`. Reason: %@", table: "Cloud", bundle: .module), detail)
    }
    public static func tabFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.tabFailed", defaultValue: "The chat moved to %1$@, but its tab didn't open: %2$@",
                              table: "Cloud", bundle: .module), machine, detail)
    }
}
