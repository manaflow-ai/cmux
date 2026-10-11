public import Foundation

/// A JSON scalar compared by type and value (`"true"` is not `true`, `1` is not `true`).
public nonisolated enum AgentPaneJSONScalar: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    /// The scalar of a Foundation JSON value; nil for an object or a list.
    public init?(_ value: Any) {
        switch value {
        case is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        default: return nil
        }
    }
}

/// The pick a gesture ticket is bound to (B1, ad349; the contract agreed with the ACP UI lead):
/// `transport.gesture {intent: {method: "session/set_mode", params: {modeId}}}` or
/// `{intent: {method: "session/set_config_option", params: {configId, value}}}`, or a prompt the
/// user sent that acpmux held for the folder trust answer,
/// `{intent: {method: "session/prompt", params: {promptId}}}`: the send's own gesture, kept for that
/// one prompt (its `_meta.acpmux.promptId`), so the Trust click's gesture goes to the trust answer.
/// Nothing else.
public nonisolated struct AgentPaneGestureIntent: Equatable, Sendable {
    /// The methods a ticket may be redeemed by, and the exact param keys of their intent.
    public static let methods: [String: Set<String>] = [
        "session/set_mode": ["modeId"],
        "session/set_config_option": ["configId", "value"],
        "session/prompt": ["promptId"],
    ]

    /// How long a ticket waits for its frame: a pick held while a harness starts, or a prompt held
    /// while the user answers the folder trust question.
    public var lifetime: TimeInterval {
        method == "session/prompt" ? AgentPaneUserGestures.heldPromptLifetime : AgentPaneUserGestures.ticketLifetime
    }

    public var method: String
    public var params: [String: AgentPaneJSONScalar]

    /// The intent of `transport.gesture`'s params, nil when they break the contract (a missing or
    /// unknown method, an unknown or missing intent param, a value that is not a scalar, or any
    /// other top-level key): `transport.intent_invalid`.
    public init?(gestureParams: [String: Any]?) {
        guard let gestureParams, Set(gestureParams.keys) == ["intent"],
              let intent = gestureParams["intent"] as? [String: Any], Set(intent.keys) == ["method", "params"],
              let method = intent["method"] as? String, let keys = Self.methods[method],
              let raw = intent["params"] as? [String: Any], Set(raw.keys) == keys else { return nil }
        var params: [String: AgentPaneJSONScalar] = [:]
        for (key, value) in raw {
            guard let scalar = AgentPaneJSONScalar(value) else { return nil }
            params[key] = scalar
        }
        self.method = method
        self.params = params
    }

    /// What a newer reserve on the same connection revokes: one ticket for set_mode, one per
    /// config option for set_config_option (a switch's model and effort picks keep theirs).
    public var slot: String {
        guard method == "session/set_config_option", case .string(let config)? = params["configId"] else { return method }
        return method + "#" + config
    }

    /// Whether a frame is the pick: the same method, and its params minus `sessionId` and `_meta`
    /// equal these params (the same keys, no extra keys, typed JSON equality).
    public func matches(method frameMethod: String?, params frameParams: [String: Any]) -> Bool {
        matches(AgentPaneGesturePick(method: frameMethod, params: frameParams))
    }

    /// Whether a frame's pick (taken off the main thread) is this intent's exact pick.
    public func matches(_ pick: AgentPaneGesturePick?) -> Bool {
        guard let pick, pick.method == method else { return false }
        return pick.params == params
    }
}

/// What a frame picks, as small values for the main actor: its method and its params other than
/// `sessionId` and `_meta`, each a JSON scalar; nil params when one is not a scalar (no match).
/// A session/prompt picks only its `_meta.acpmux.promptId` (its blocks are no pick).
public nonisolated struct AgentPaneGesturePick: Equatable, Sendable {
    public var method: String?
    public var params: [String: AgentPaneJSONScalar]?

    public init(method: String?, params: [String: Any]) {
        self.method = method
        if method == "session/prompt" {
            let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            self.params = (acpmux?["promptId"] as? String).map { ["promptId": .string($0)] }
            return
        }
        var scalars: [String: AgentPaneJSONScalar] = [:]
        for (key, value) in params where key != "sessionId" && key != "_meta" {
            guard let scalar = AgentPaneJSONScalar(value) else {
                self.params = nil
                return
            }
            scalars[key] = scalar
        }
        self.params = scalars
    }
}
