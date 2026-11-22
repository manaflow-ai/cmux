public import Foundation

/// The value that closes a request, one case per built-in kind
/// (feed.md 3.4, "Answer value"). The owner validates it against the kind;
/// the client checks choices before sending (`FeedChoiceValidation`).
public nonisolated enum FeedAnswerValue: Sendable, Equatable {
    case text(String)
    case choice([String: FeedChoiceSelection])
    case approve(Decision)
    case confirm(Bool)
    case signIn(BrowserStatus)
    case passkey(BrowserStatus)
    case review(Verdict, comment: String?)
    case input([String: FeedJSON])
    case files([FeedAttachment])
    case handoff(HandoffStatus, note: String?)
    case custom(FeedJSON)

    public struct Decision: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable { case allow, deny }
        public var outcome: Outcome
        public var scope: FeedApproveScope?
        public var reason: String?

        public init(_ outcome: Outcome, scope: FeedApproveScope? = nil, reason: String? = nil) {
            self.outcome = outcome
            self.scope = scope
            self.reason = reason
        }
    }

    /// `sign-in` and `passkey` answers come from the Mac's browser system only.
    public enum BrowserStatus: String, Sendable, Equatable {
        case completed, signedIn = "signed_in", cancelled, failed, unavailable, originChanged = "origin_changed"
    }

    public enum Verdict: String, Sendable, Equatable {
        case approve
        case requestChanges = "request_changes"
        case comment
    }

    public enum HandoffStatus: String, Sendable, Equatable {
        case resumed
        case takenOver = "taken_over"
        case declined
    }
}

/// One choice question's answer: the selected option ids, plus free text
/// when the question allows "Other".
public nonisolated struct FeedChoiceSelection: Sendable, Equatable, Hashable {
    public var selected: [String]
    public var other: String?

    public init(selected: [String] = [], other: String? = nil) {
        self.selected = selected
        self.other = other
    }

    /// Toggles `option`; a single-select question keeps one option and
    /// drops "Other".
    public mutating func toggle(_ option: String, multi: Bool) {
        if let index = selected.firstIndex(of: option) {
            selected.remove(at: index)
        } else if multi {
            selected.append(option)
        } else {
            selected = [option]
            other = nil
        }
    }
}

/// Set once, by the first accepted answer.
public nonisolated struct FeedAnswerRecord: Sendable, Equatable {
    public var value: FeedAnswerValue
    /// The user principal that answered.
    public var by: String
    /// The device name ("iPhone", "MacBook Pro").
    public var device: String
    public var at: Date

    public init(value: FeedAnswerValue, by: String, device: String, at: Date) {
        self.value = value
        self.by = by
        self.device = device
        self.at = at
    }
}
