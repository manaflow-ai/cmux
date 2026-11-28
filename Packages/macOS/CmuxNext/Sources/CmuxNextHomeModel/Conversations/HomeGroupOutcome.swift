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
    /// I am a read-only member of the group (`read_only`): I can read it, not change or post to it.
    case readOnly
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
    /// group's owner may. The mapping is `compose.group.outcome`'s.
    public init(rejection: HomeRejection, naming: String, removing: Bool = false) {
        let request = OutcomeRequest(rejection: .init(rejection), naming: naming, removing: removing)
        let reply: OutcomeReply = HomeComposeRules().call(
            "group.outcome", request,
            fallback: OutcomeReply(outcome: .init(kind: "refused", name: nil, reason: "")))
        self = reply.outcome.groupOutcome
    }

    /// The action worked (a queued send counts).
    public var succeeded: Bool {
        switch self {
        case .done, .queued, .left: true
        default: false
        }
    }

    /// What the sheet or a refused action says; nil when it worked.
    public var message: String? { HomeModelStrings.groupOutcome(self) }
}

extension HomeComposeRules {
    /// ``HomeRejection`` (`compose::group::Rejection`, tagged by `kind`).
    package nonisolated struct Rejection: Encodable, Sendable {
        var kind: String
        var reason: String?

        package init(_ rejection: HomeRejection) {
            switch rejection {
            case .ownerUnreachable: kind = "ownerUnreachable"
            case .notAuthorized: kind = "notAuthorized"
            case .invalid(let reason):
                kind = "invalid"
                self.reason = reason
            case .rateLimited: kind = "rateLimited"
            case .indeterminate: kind = "indeterminate"
            }
        }
    }
}

extension HomeComposeRules.Outcome {
    /// The outcome as the sheet's type.
    package var groupOutcome: HomeGroupOutcome {
        switch kind {
        case "done": .done
        case "queued": .queued
        case "left": .left
        case "notReachable": .notReachable(name ?? "")
        case "ownerOnly": .ownerOnly
        case "forbidden": .forbidden
        case "readOnly": .readOnly
        case "notAGroup": .notAGroup
        case "unknownConversation": .unknownConversation
        case "unknownPerson": .unknownPerson(name ?? "")
        case "notAMember": .notAMember(name ?? "")
        case "cannotMute": .cannotMute
        case "emptyText": .emptyText
        case "noPeople": .noPeople
        case "offline": .offline
        case "rateLimited": .rateLimited
        case "tooMany": .tooMany
        default: .refused(reason ?? "")
        }
    }
}

/// `compose.group.outcome`'s request and reply.
private nonisolated struct OutcomeRequest: Encodable {
    var rejection: HomeComposeRules.Rejection
    var naming: String
    var removing: Bool
}

private nonisolated struct OutcomeReply: Decodable {
    var outcome: HomeComposeRules.Outcome
}
