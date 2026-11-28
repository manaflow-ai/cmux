import Foundation

/// What a banner action sends as `feed.answer {item, answer}`.
public enum FeedAnswer: Hashable, Sendable {
    case decision(allow: Bool, scope: String?)
    case confirmed(Bool)
    case text(String)

    /// The answer for one banner action, or nil when the action only opens
    /// the app (or carries no usable text).
    public init?(action: FeedPushAction, text: String? = nil) {
        switch action {
        case .allow: self = .decision(allow: true, scope: nil)
        case .allowForSession: self = .decision(allow: true, scope: "session")
        case .deny: self = .decision(allow: false, scope: nil)
        case .confirm: self = .confirmed(true)
        case .cancel: self = .confirmed(false)
        case .reply:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self = .text(trimmed)
        case .openOnMac: return nil
        }
    }

    /// The `answer` object.
    public var value: JSONValue {
        switch self {
        case .decision(let allow, let scope):
            var object: [String: JSONValue] = ["decision": .string(allow ? "allow" : "deny")]
            if let scope { object["scope"] = .string(scope) }
            return .object(object)
        case .confirmed(let value): return .object(["confirmed": .bool(value)])
        case .text(let value): return .object(["text": .string(value)])
        }
    }

    /// The `answer` object as Foundation JSON (tests, logging).
    public var json: [String: Any] { (value.foundation as? [String: Any]) ?? [:] }
}
