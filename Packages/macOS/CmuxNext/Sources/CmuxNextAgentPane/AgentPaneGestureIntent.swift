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
/// A permission answer's intent names its session, prompt and option, and a question's `answers`
/// and `annotations` (objects) when it has them: the ticket is then for exactly those, compared by
/// the sha256 of their canonical JSON bytes (``AcpmuxSecretKey/canonicalDigest(_:)``), never by
/// `String` equality, which counts canonically equivalent Unicode as equal. Nothing else.
public nonisolated struct AgentPaneGestureIntent: Equatable, Sendable {
    /// The methods a ticket may be redeemed by, and the exact param keys of their intent.
    public static let methods: [String: Set<String>] = [
        "session/set_mode": ["modeId"],
        "session/set_config_option": ["configId", "value"],
        "session/prompt": ["promptId"],
        // cx-0q7o: the person's pick of one option of one prompt; only such an allow is signed
        // for another daemon run.
        "_acpmux/permission_respond": ["sessionId", "permissionId", "optionId"],
    ]

    /// Intent params a method may add to its keys: objects, each held as its canonical digest. A
    /// question's answers and annotations, so a ticket taken for one answer never redeems another.
    public static let objectKeys: [String: Set<String>] = [
        "_acpmux/permission_respond": ["answers", "annotations"],
    ]

    /// Intent params a method may add that bind the ticket without being part of its pick: a
    /// send's chat (`sessionId`). A send ticket bound to a chat is the one ticket an upload of that
    /// send may hold (``AgentPaneUserGestures/holdForUpload(_:upload:connection:sessionId:promptId:)``),
    /// and only a prompt to that chat redeems it.
    public static let bindingKeys: [String: Set<String>] = [
        "session/prompt": ["sessionId"],
    ]

    /// How long a ticket waits for its frame: a pick held while a harness starts, or a prompt held
    /// while the user answers the folder trust question.
    public var lifetime: TimeInterval {
        method == "session/prompt" ? AgentPaneUserGestures.heldPromptLifetime : AgentPaneUserGestures.ticketLifetime
    }

    public var method: String
    public var params: [String: AgentPaneJSONScalar]
    /// The chat a send ticket is for (``bindingKeys``); nil when the intent names none.
    public var sessionId: String?

    /// The intent of `transport.gesture`'s params, nil when they break the contract (a missing or
    /// unknown method, an unknown or missing intent param, a value that is not a scalar, or any
    /// other top-level key): `transport.intent_invalid`.
    public init?(gestureParams: [String: Any]?) {
        guard let gestureParams, Set(gestureParams.keys) == ["intent"],
              let intent = gestureParams["intent"] as? [String: Any], Set(intent.keys) == ["method", "params"],
              let method = intent["method"] as? String, let keys = Self.methods[method],
              let raw = intent["params"] as? [String: Any], keys.isSubset(of: raw.keys),
              Set(raw.keys).subtracting(keys).isSubset(of: (Self.objectKeys[method] ?? []).union(Self.bindingKeys[method] ?? []))
        else { return nil }
        var params: [String: AgentPaneJSONScalar] = [:]
        for (key, value) in raw {
            if Self.bindingKeys[method]?.contains(key) == true {
                guard let session = value as? String, !session.isEmpty else { return nil }
                sessionId = session
                continue
            }
            if !keys.contains(key) {
                // A question's answers or annotations: an object, by its canonical digest.
                guard value is [String: Any], let digest = AcpmuxSecretKey.canonicalDigest(value) else { return nil }
                params[key] = .string(digest)
                continue
            }
            guard let scalar = AgentPaneJSONScalar(value) else { return nil }
            params[key] = scalar
        }
        // A Cloud hand-off labels the same prompt `handoff-<turn>-<id>` on the wire. Keep the
        // ticket bound to the prompt's own id so its early reservation still redeems after that
        // label is assigned, while a doubly labelled id remains distinct.
        if method == "session/prompt", case .string(let id)? = params["promptId"] {
            params["promptId"] = .string(AgentPaneHandoffPrompt(id: id).ownID)
        }
        self.method = method
        self.params = params
    }

    /// What a newer reserve on the same connection revokes: one ticket for set_mode, one per
    /// config option, and one per prompt id. A rapid later Enter must not revoke an earlier
    /// prompt's proof before its frame reaches the relay.
    public var slot: String {
        switch (method, params["configId"], params["promptId"]) {
        case ("session/set_config_option", .string(let config)?, _): return method + "#" + config
        case ("session/prompt", _, .string(let promptId)?): return method + "#" + promptId
        default: return method
        }
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
            self.params = (acpmux?["promptId"] as? String).map {
                ["promptId": .string(AgentPaneHandoffPrompt(id: $0).ownID)]
            }
            return
        }
        // A permission answer's pick names its session too (the ticket binds the prompt), and a
        // question's answers and annotations by their canonical digest (the ticket binds them too).
        if method == "_acpmux/permission_respond" {
            guard let session = params["sessionId"] as? String, let permission = params["permissionId"] as? String,
                  let option = params["optionId"] as? String else {
                self.params = nil
                return
            }
            var pick: [String: AgentPaneJSONScalar] = ["sessionId": .string(session), "permissionId": .string(permission),
                                                       "optionId": .string(option)]
            for key in AgentPaneGestureIntent.objectKeys["_acpmux/permission_respond"] ?? [] {
                guard let value = params[key], !(value is NSNull) else { continue }
                guard value is [String: Any], let digest = AcpmuxSecretKey.canonicalDigest(value) else {
                    self.params = nil
                    return
                }
                pick[key] = .string(digest)
            }
            self.params = pick
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
