public import CmuxNextCloud
public import Foundation

/// Move to Cloud's text (the App's `CloudMove`, `CloudStartChat`, `CloudBringBack`). Keys live in
/// Resources/Cloud.xcstrings with every app locale.
public struct CloudMoveStrings {
    public init() {}
    public static var moving: String {
        String(localized: "cloud.move.moving", defaultValue: "Moving this chat to Cloud…", table: "Cloud", bundle: .localizedModule)
    }
    public static func moved(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.moved", defaultValue: "This chat now runs on %@.", table: "Cloud", bundle: .localizedModule), machine)
    }
    /// This chat's own Cloud VM could not start; `cause` is Rust's (`signIn`, `planLimit`, `capacity`, `offline`), none when not known.
    /// Each chat has its own VM, so this never says a shared pool had none free.
    public static func vmCouldNotStart(cause: String?) -> String {
        switch cause {
        case "signIn": String(localized: "cloud.move.vmCouldNotStart.signIn", defaultValue: "Its Cloud VM could not start: sign in to cmux Cloud first.", table: "Cloud", bundle: .localizedModule)
        case "planLimit": String(localized: "cloud.move.vmCouldNotStart.planLimit", defaultValue: "Its Cloud VM could not start: your plan's limit of Cloud machines is reached.", table: "Cloud", bundle: .localizedModule)
        case "capacity": String(localized: "cloud.move.vmCouldNotStart.capacity", defaultValue: "Its Cloud VM could not start: Cloud has no capacity for it right now. Try again in a moment.", table: "Cloud", bundle: .localizedModule)
        case "offline": String(localized: "cloud.move.vmCouldNotStart.offline", defaultValue: "Its Cloud VM could not start: this Mac could not reach Cloud.", table: "Cloud", bundle: .localizedModule)
        default: String(localized: "cloud.move.vmCouldNotStart", defaultValue: "Its Cloud VM could not start.", table: "Cloud", bundle: .localizedModule)
        }
    }
    public static var retry: String { String(localized: "cloud.move.retry", defaultValue: "Retry", table: "Cloud", bundle: .localizedModule) }
    /// An agent's or a socket's run of a chat place action (Local, Cloud, Auto, Evacuate, Bring Back All, Cancel, Retry).
    public static var placeIsPersons: String {
        String(localized: "cloud.place.personOnly", defaultValue: "Only you can move chats between this Mac and Cloud, with a click in cmux.", table: "Cloud", bundle: .localizedModule)
    }
    /// A second Evacuate or Bring Back All while one runs.
    public static var bulkRunning: String {
        String(localized: "cloud.place.bulkRunning", defaultValue: "Chats are already moving. Wait for that to finish, or cancel it.", table: "Cloud", bundle: .localizedModule)
    }
    /// An Evacuate or Bring Back All's chats that never started because the Cloud account or team changed under it.
    public static var identityChanged: String {
        String(localized: "cloud.place.identityChanged", defaultValue: "Not moved: the Cloud account or team changed after this started.", table: "Cloud", bundle: .localizedModule)
    }
    public static var notAChat: String {
        String(localized: "cloud.move.notAChat", defaultValue: "Move to Cloud works on a chat tab.", table: "Cloud", bundle: .localizedModule)
    }
    public static var alreadyRemote: String {
        String(localized: "cloud.move.alreadyRemote", defaultValue: "This chat already runs on another machine.", table: "Cloud", bundle: .localizedModule)
    }
    public static var noSession: String {
        String(localized: "cloud.move.noSession", defaultValue: "Send a first message, then move this chat.", table: "Cloud", bundle: .localizedModule)
    }
    public static var noFolder: String {
        String(localized: "cloud.move.noFolder", defaultValue: "This chat has no folder to copy to the machine.", table: "Cloud", bundle: .localizedModule)
    }
    public static var homeFolder: String {
        String(localized: "cloud.move.homeFolder", defaultValue: "Move to Cloud copies a project folder, never your home folder. Start the chat in a project folder first.",
               table: "Cloud", bundle: .localizedModule)
    }
    /// `cloud.startChat`: the account or team changed while the send started (``CloudStartChat/checkAccount(_:now:listCurrent:)``).
    public static var startChatAccountChanged: String {
        String(localized: "cloud.startChat.accountChanged",
               defaultValue: "Your Cloud account or team changed while this chat was starting, so nothing was copied. Send it again in the account you want it in.",
               table: "Cloud", bundle: .localizedModule)
    }
    /// `cloud.startChat`: the machine list of the account signed in now could not be read.
    public static var startChatListUnread: String {
        String(localized: "cloud.startChat.listUnread",
               defaultValue: "Couldn't read the Cloud machines of the account signed in now, so this chat stays on this Mac. Try again in a moment.",
               table: "Cloud", bundle: .localizedModule)
    }
    public static func relativePath(_ path: String) -> String {
        String(format: String(localized: "cloud.move.relativePath", defaultValue: "Move to Cloud needs a full folder path, not %@.", table: "Cloud", bundle: .localizedModule),
               path)
    }
    /// A move's or bring back's machine is gone from the person's machines: the chat can't reach it again.
    public static var machineDeleted: String {
        String(localized: "cloud.move.machineDeleted", defaultValue: "This chat's Cloud machine was deleted.", table: "Cloud", bundle: .localizedModule)
    }
    public static func noSuchMachine(_ id: String) -> String {
        String(format: String(localized: "cloud.move.noSuchMachine", defaultValue: "No Cloud machine has the id %@.", table: "Cloud", bundle: .localizedModule), id)
    }
    public static func notConnected(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.notConnected", defaultValue: "%@ didn't connect. Retry once it's online.", table: "Cloud", bundle: .localizedModule), machine)
    }
    /// The machine did not connect, and its last connect said why (the link's own words); no reason: ``notConnected(_:)``.
    /// A bare `relay` (the machine never came to the relay: it did not come online) is a code, not words a person
    /// can act on ("didn't connect: relay. Retry when that's fixed."), so it reads as no reason.
    public static func notConnected(_ machine: String, because reason: String?) -> String {
        guard let reason, reason != "relay" else { return notConnected(machine) }
        return String(format: String(localized: "cloud.move.notConnectedBecause", defaultValue: "%1$@ didn't connect: %2$@. Retry when that's fixed.", table: "Cloud", bundle: .localizedModule), machine, reason)
    }
    public static func syncFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.syncFailed", defaultValue: "Couldn't copy the folder to %1$@: %2$@", table: "Cloud", bundle: .localizedModule),
               machine, detail)
    }
    public static var unresolved: String {
        String(localized: "cloud.move.unresolved", defaultValue: "The move didn't finish, so the chat is paused. Retry to finish it.", table: "Cloud", bundle: .localizedModule)
    }
    /// After a relaunch: the chat's move stopped before the chat moved (cx-rppd.16).
    public static var unfinishedMove: String {
        String(localized: "cloud.move.unfinishedMove", defaultValue: "Moving this chat to Cloud didn't finish. Retry to finish it, or dismiss to keep it here.",
               table: "Cloud", bundle: .localizedModule)
    }
    /// After a relaunch: the chat moved, but its tab on the machine never opened (cx-rppd.16).
    public static var unfinishedShow: String {
        String(localized: "cloud.move.unfinishedShow", defaultValue: "This chat moved to Cloud, but its tab there didn't open. Retry to open it.",
               table: "Cloud", bundle: .localizedModule)
    }
    public static var inProgress: String {
        String(localized: "cloud.move.inProgress", defaultValue: "This chat is already moving. Retry in a moment.", table: "Cloud", bundle: .localizedModule)
    }
    public static func teamMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.teamMachine", defaultValue: "%@ is a team machine. Chats move only to a machine you own.",
                              table: "Cloud", bundle: .localizedModule), machine)
    }
    /// The machine's cmux-tui is too old for the move (`machine_outdated`, cx-rppd.13).
    public static func outdatedMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.outdatedMachine", defaultValue: "%@ runs an older cmux that can't take this chat yet. Update the machine to move it.",
                              table: "Cloud", bundle: .localizedModule), machine)
    }
    /// What a link CLI answers when the machine's cmux-tui is too old for it (cmux-tui `link/machine_gate.rs`).
    public static let outdatedCode = CloudOutdatedMachine.code
    public static func unknownMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unknownMachine", defaultValue: "cmux can't confirm who owns %@, so the chat stays on this Mac.",
                              table: "Cloud", bundle: .localizedModule), machine)
    }
    public static func unreachable(_ machine: String) -> String {
        String(format: String(localized: "cloud.move.unreachable", defaultValue: "Lost the connection to %@ during the move. Retry to finish it.",
                              table: "Cloud", bundle: .localizedModule), machine)
    }
    /// A `cmux link` answer's value, or its error as the person reads it: a refusal a paid plan lifts is
    /// ``CloudAPIError/planRequired(message:upgradeURL:plan:)``, one its size needs another plan for ``CloudSizeLocked``,
    /// any other one a ``CloudMoveFailure``.
    public static func checked<T>(_ answer: (CloudMoveCLI.Answer, T)) throws -> T {
        guard answer.0.ok else {
            if let code = answer.0.errorCode, CloudSizeLocked.isCode(code) { throw CloudSizeLocked(details: answer.0.sizeLocked) }
            if let tooSmall = CloudSeedRefusal.planRefusal(answer.0) { throw tooSmall } // the folder is more than its machine has room for
            throw answer.0.errorCode == "cloud.plan.required" ? CloudAPIError.planRequired(message: nil, upgradeURL: nil) as any Error : CloudMoveFailure(message: moveFailed(answer.0.error ?? answer.0.errorCode ?? ""), sendAgain: answer.0.retryable)
        }
        return answer.1
    }
    public static func moveFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.move.failedPlain", defaultValue: "Couldn't move the chat. %@", table: "Cloud", bundle: .localizedModule), detail)
    }
    /// A move to the person's own machine whose chosen agent login could not be read: it stays here.
    public static func loginFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.loginFailed", defaultValue: "The chat stays here: your agent login for %1$@ couldn't be read: %2$@",
                              table: "Cloud", bundle: .localizedModule), machine, detail)
    }
    public static func tabFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.move.tabFailed", defaultValue: "The chat moved to %1$@, but its tab didn't open: %2$@",
                              table: "Cloud", bundle: .localizedModule), machine, detail)
    }
    /// The app server's refusal of a create at the team's machine count limit (upstream `cloud.quota.vm_limit`).
    public nonisolated static let machineLimitCode = "cmux.cloud.vm_limit"
    public nonisolated static var machineLimit: String {
        String(localized: "cloud.error.machineLimit", defaultValue: "This team is at its Cloud machine limit, paused machines included. Delete a machine you don't need, then try again.", table: "Cloud", bundle: .localizedModule)
    }
    /// The app server's refusal of a request sent too often (upstream `cloud.rate_limited`).
    public nonisolated static let rateLimitedCode = "cmux.cloud.rate_limited"
    public nonisolated static var rateLimited: String {
        String(localized: "cloud.error.rateLimited", defaultValue: "Cloud is getting too many requests from this account right now. Wait a minute, then try again.", table: "Cloud", bundle: .localizedModule)
    }
}

/// An app-server refusal a person can act on reads as its own sentence wherever an error is put in plain words
/// (`PlainErrorText.personal`): a create at the machine limit or one sent too often says so, not "Something went
/// wrong" (cmux#45774: a Cloud start refused `cloud.rate_limited` read "Couldn't move the chat. Something went wrong.").
/// Any other code has no description here and keeps the caller's wording.
extension CloudAppOpFailure: LocalizedError {
    public var errorDescription: String? {
        switch code {
        case CloudMoveStrings.machineLimitCode: CloudMoveStrings.machineLimit
        case CloudMoveStrings.rateLimitedCode: CloudMoveStrings.rateLimited
        default: nil
        }
    }
}
