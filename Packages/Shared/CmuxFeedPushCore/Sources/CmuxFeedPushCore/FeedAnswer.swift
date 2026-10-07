import Foundation

/// What a banner action sends as `feed.answer {item, answer}`, in the kind's
/// answer schema (feed.md 3.4).
public enum FeedAnswer: Hashable, Sendable {
    /// `approve`: scope nil lets the owner apply the prompt's default.
    case decision(allow: Bool, scope: String?)
    case confirmed(Bool)
    case text(String)
    /// `review`: approve, or request changes with a comment.
    case verdict(approve: Bool, comment: String?)

    /// The answer for one banner action, or nil when the action only opens
    /// the app, triages, or carries no usable text.
    public init?(action: FeedPushAction, text: String? = nil) {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .allow: self = .decision(allow: true, scope: nil)
        case .allowOnce: self = .decision(allow: true, scope: "once")
        case .allowForSession: self = .decision(allow: true, scope: "session")
        case .deny: self = .decision(allow: false, scope: nil)
        case .confirm: self = .confirmed(true)
        case .cancel: self = .confirmed(false)
        case .reply:
            guard !trimmed.isEmpty else { return nil }
            self = .text(trimmed)
        case .approvePlan: self = .verdict(approve: true, comment: nil)
        case .requestChanges:
            // An empty comment opens the item, where the user can write one.
            guard !trimmed.isEmpty else { return nil }
            self = .verdict(approve: false, comment: trimmed)
        case .markRead, .openOnMac: return nil
        }
    }

    /// The `answer` object.
    public var value: JSONValue {
        switch self {
        case .decision(let allow, let scope):
            var object: [String: JSONValue] = ["decision": .string(allow ? "allow" : "deny")]
            if allow, let scope { object["scope"] = .string(scope) }
            return .object(object)
        case .confirmed(let value): return .object(["confirmed": .bool(value)])
        case .text(let value): return .object(["text": .string(value)])
        case .verdict(let approve, let comment):
            var object: [String: JSONValue] = ["verdict": .string(approve ? "approve" : "request_changes")]
            if let comment { object["comment"] = .string(comment) }
            return .object(object)
        }
    }

    /// The `answer` object as Foundation JSON (tests, logging).
    public var json: [String: Any] { (value.foundation as? [String: Any]) ?? [:] }
}
