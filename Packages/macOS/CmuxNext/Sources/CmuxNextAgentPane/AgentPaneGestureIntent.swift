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
/// `{intent: {method: "session/set_config_option", params: {configId, value}}}`. Nothing else.
public nonisolated struct AgentPaneGestureIntent: Equatable, Sendable {
    /// The methods a ticket may be redeemed by, and the exact param keys of their intent.
    public static let methods: [String: Set<String>] = [
        "session/set_mode": ["modeId"],
        "session/set_config_option": ["configId", "value"],
    ]

    public var method: String
    public var params: [String: AgentPaneJSONScalar]

    /// The intent of `transport.gesture`'s params, nil when they break the contract (a missing or
    /// unknown method, an unknown or missing intent param, a value that is not a scalar, or any
    /// other top-level key): `transport.intent_invalid`.
    public init?(gestureParams: [String: Any]?) {
        guard let gestureParams, gestureParams["intent"] != nil, // RED STUB: other top-level keys pass
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

    /// Whether a frame is the pick: the same method, and its params minus `sessionId` and `_meta`
    /// equal these params (the same keys, no extra keys, typed JSON equality).
    public func matches(method frameMethod: String?, params frameParams: [String: Any]) -> Bool {
        guard frameMethod == method else { return false }
        let rest = frameParams.filter { $0.key != "sessionId" && $0.key != "_meta" }
        guard Set(rest.keys) == Set(params.keys) else { return false }
        return rest.allSatisfy { AgentPaneJSONScalar($0.value) == params[$0.key] }
    }
}
