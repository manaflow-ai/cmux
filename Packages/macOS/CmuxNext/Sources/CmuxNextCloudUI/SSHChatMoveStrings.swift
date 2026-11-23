public import CmuxNextCloud
import Foundation

/// Move to SSH Machine's text (the App's `SSHChatMove`). Keys live in Resources/Cloud.xcstrings.
public struct SSHChatMoveStrings {
    public init() {}
    /// A refusal code of Rust's `moves::targets::ssh_move`, in the person's words.
    public static func refusal(_ code: String) -> String {
        switch code {
        case "not_offered": String(localized: "cloud.sshMove.notOffered", defaultValue: "That chat can't move to that machine now.", table: "Cloud", bundle: .localizedModule)
        case "unknown_peer": String(localized: "cloud.sshMove.unknownPeer", defaultValue: "This Mac's agents don't reach that machine. Add it again in Settings > Devices.",
                                    table: "Cloud", bundle: .localizedModule)
        case "not_started": String(localized: "cloud.sshMove.notStarted", defaultValue: "That chat hasn't started yet.", table: "Cloud", bundle: .localizedModule)
        default: failed
        }
    }
    /// What a run that did not move the chat says: the refusal in the person's words, else acpmux's.
    public static func message(_ outcome: CloudMoveTargetRules.MoveResult) -> String {
        switch outcome {
        case .moved: ""
        case .refused(let code): refusal(code)
        case .needsConfirmation(let code, _): refusal(code)
        case .failed(let words): words.isEmpty ? failed : words
        }
    }
    public static var failed: String {
        String(localized: "cloud.sshMove.failed", defaultValue: "The chat did not move.", table: "Cloud", bundle: .localizedModule)
    }
    public static var tabFailed: String {
        String(localized: "cloud.sshMove.tabFailed", defaultValue: "The chat moved, but its tab didn't open here.", table: "Cloud", bundle: .localizedModule)
    }
    public static var personOnly: String {
        String(localized: "cloud.sshMove.personOnly", defaultValue: "Only a person can move a chat to another machine.", table: "Cloud", bundle: .localizedModule)
    }
    public static var moveTitle: String {
        String(localized: "cloud.sshMove.moveTitle", defaultValue: "Move chat", table: "Cloud", bundle: .localizedModule)
    }
    public static var afterTurn: String {
        String(localized: "cloud.sshMove.afterTurn", defaultValue: "Move after this turn", table: "Cloud", bundle: .localizedModule)
    }
    public static var moveNow: String {
        String(localized: "cloud.sshMove.moveNow", defaultValue: "Move now", table: "Cloud", bundle: .localizedModule)
    }
    public static var carryChanges: String {
        String(localized: "cloud.sshMove.carryChanges", defaultValue: "Move with changes", table: "Cloud", bundle: .localizedModule)
    }
    public static var running: String {
        String(localized: "cloud.sshMove.running", defaultValue: "This chat has a running turn.", table: "Cloud", bundle: .localizedModule)
    }
    public static var dirty: String {
        String(localized: "cloud.sshMove.dirty", defaultValue: "Uncommitted changes will move with this chat.", table: "Cloud", bundle: .localizedModule)
    }
}
