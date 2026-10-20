public import CmuxHomeCore

/// What a group action (rename, add, remove, leave, Hide Alerts, send) ended with, for the
/// sheet's status line and an action's refusal.
public enum HomeGroupOutcome: Hashable, Sendable {
    /// The owner took it.
    case done
    /// The message waits for the owner and goes when it is back.
    case queued
    /// I left the group; it is gone from my list.
    case left
    /// The owner refused a person the user cannot reach (`not_reachable`); the sheet offers an invite by email.
    case notReachable(String)
    /// Removing someone else: only the group's owner may.
    case ownerOnly
    /// The owner refused the change for this user (`forbidden`).
    case forbidden
    /// A DM or a Chief conversation: no name, members or leave (`kind_forbids`).
    case notAGroup
    /// No conversation with that id is listed.
    case unknownConversation
    /// No contact or member has that name, email or id.
    case unknownPerson(String)
    /// That person is not in the conversation.
    case notAMember(String)
    /// The conversation has no Hide Alerts (a local one).
    case cannotMute
    /// Nothing to send.
    case emptyText
    /// No one was named to add.
    case noPeople
    /// The owner is offline: nothing was sent.
    case offline
    /// Too many changes in a short time.
    case rateLimited
    /// The group is full (64 people).
    case tooMany
    /// Refused for another reason; the text is the owner's (may be empty).
    case refused(String)

    /// The owner's refusal. `removing`: the op removed someone else, so `forbidden` means only the
    /// group's owner may.
    public init(rejection: HomeRejection, naming: String, removing: Bool = false) {
        switch rejection {
        case .ownerUnreachable: self = .offline
        case .rateLimited: self = .rateLimited
        case .notAuthorized: self = removing ? .ownerOnly : .forbidden
        case .indeterminate: self = .refused("")
        case .invalid(let reason):
            switch reason {
            case "forbidden": self = removing ? .ownerOnly : .forbidden
            case "not_reachable": self = .notReachable(naming)
            case "kind_forbids": self = .notAGroup
            case "unknown_conversation": self = .unknownConversation
            case "not_participant": self = .notAMember(naming)
            case "too_many_participants": self = .tooMany
            case "home.rate_limited": self = .rateLimited
            default: self = .refused(reason)
            }
        }
    }

    /// The action worked (a queued send counts).
    public var succeeded: Bool {
        switch self {
        case .done, .queued, .left: true
        default: false
        }
    }

    /// What the sheet or a refused action says; nil when it worked.
    public var message: String? { HomeConversationStrings.groupOutcome(self) }
}
