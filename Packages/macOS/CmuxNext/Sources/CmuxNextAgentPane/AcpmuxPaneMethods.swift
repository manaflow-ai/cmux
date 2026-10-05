public import Foundation

/// The frames the agent pane may send to acpmux through the host's socket (``AgentPaneTransport``).
/// Default deny: a method not listed here never reaches the daemon.
///
/// The list is exactly what the pane sends today over its connection with the app's native git
/// route, read from `webviews/src/agent-session/acpmux`: every `this.request(...)` and raw
/// `socket.send` in `direct.ts`, plus `handoff/protocol.ts` `HANDOFF_OPS`,
/// `permissions/protocol.ts` `PERMISSION_GROUP_OPS`, `operations.ts` `FORK_OP` and `direct.ts`
/// `PREWARM_METHOD`. Not listed: `git.diff`, `git.status`, `git.checkpoint.diff` and
/// `file.search`, which go to the socket only in mock mode (`gitRoute == "daemon"`, an in-page
/// daemon that never uses this transport); the app sends them to the host bridge instead.
/// The pane sends no JSON-RPC responses, so a frame without a method is refused too.
/// Review: the protocol/origin lead (ad349). Changing the list needs that review.
public nonisolated enum AcpmuxPaneMethods {
    /// The first frame of every connection, and only the first.
    public static let initialize = "initialize"

    /// Requests (`id` present).
    public static let requests: Set<String> = [
        // Sessions (direct.ts).
        "session/new", "session/prompt", "session/set_model", "session/set_mode", "session/set_config_option",
        // acpmux extensions (direct.ts).
        "_acpmux/watch", "_acpmux/events", "_acpmux/attach", "_acpmux/detach", "_acpmux/warm",
        "_acpmux/kill", "_acpmux/prewarm", "_acpmux/harnesses", "_acpmux/models", "_acpmux/permission_respond",
        // Hand-off (handoff/protocol.ts HANDOFF_OPS).
        "_acpmux/handoff_prepare", "_acpmux/handoff_get", "_acpmux/handoff_draft", "_acpmux/handoff_start",
        "_acpmux/handoff_discard",
        // Grouped permissions (permissions/protocol.ts PERMISSION_GROUP_OPS).
        "_acpmux/permission_groups", "_acpmux/permission_group_respond", "_acpmux/permission_chat_revoke",
        // Fork (operations.ts FORK_OP) and folder trust (direct.ts trustGet/trustSet).
        "acp.session.fork", "acp.trust.get", "acp.trust.set",
    ]

    /// Notifications (no `id`).
    public static let notifications: Set<String> = ["session/cancel"]

    /// Longest frame the page may send (a prompt with attachments is the largest).
    public static let maximumFrameBytes = 32 << 20

    /// What the relay does with one page frame.
    public nonisolated enum Decision: Equatable, Sendable {
        /// Send `text` (the first frame with the LocalApp token added when there is one).
        case send(String)
        /// Refuse it. `requestID` is the JSON-RPC id of a refused request (its raw JSON), so the
        /// relay can answer it with an error frame instead of leaving the page waiting.
        case refuse(AgentPaneTransportError, method: String?, requestID: String?)
    }

    /// The decision for `text`, the page's `isFirst` frame or a later one.
    public static func decide(_ text: String, isFirst: Bool, localAppToken: String?) -> Decision {
        guard text.utf8.count <= maximumFrameBytes else { return .refuse(.frameTooLarge, method: nil, requestID: nil) }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else {
            return .refuse(.invalidFrame, method: nil, requestID: nil)
        }
        let id = object["id"].flatMap(rawID)
        guard let method = object["method"] as? String else { return .refuse(.methodRefused, method: nil, requestID: nil) }
        // C1: no page frame may make the harness spawn a command.
        if let params = object["params"], carriesServers(params) {
            return .refuse(.mcpServersRefused, method: method, requestID: id)
        }
        if isFirst {
            guard method == initialize, id != nil else { return .refuse(.firstFrameNotInitialize, method: method, requestID: id) }
            guard let localAppToken else { return .send(text) }
            var params = object["params"] as? [String: Any] ?? [:]
            var meta = params["_meta"] as? [String: Any] ?? [:]
            var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
            acpmux["localAppToken"] = localAppToken
            meta["acpmux"] = acpmux
            params["_meta"] = meta
            object["params"] = params
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
                return .refuse(.invalidFrame, method: method, requestID: id)
            }
            return .send(String(decoding: data, as: UTF8.self))
        }
        let allowed = id == nil ? notifications.contains(method) : requests.contains(method)
        return allowed ? .send(text) : .refuse(.methodRefused, method: method, requestID: id)
    }

    /// The methods allowed only for a session this pane started or shows (``AcpmuxPaneSessions``).
    public static let sessionScoped: Set<String> = ["_acpmux/kill", "_acpmux/permission_respond", "_acpmux/permission_group_respond"]

    /// The error frame that answers a refused request, as the daemon would answer an unknown one.
    /// `rootRequested`: the host offered the user to add the refused folder as a root.
    public static func refusal(requestID: String, error: AgentPaneTransportError, method: String?, rootRequested: Bool = false) -> String {
        var data: [String: Any] = ["code": error.rawValue, "origin": "native"]
        if let method { data["method"] = method }
        if rootRequested { data["rootRequested"] = true }
        let body: [String: Any] = ["code": -32601, "message": "Refused by the cmux host", "data": data]
        let encoded = (try? JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return #"{"jsonrpc":"2.0","id":"# + requestID + #","error":"# + encoded + "}"
    }

    /// The frames that GRANT something and so need a fresh user gesture (ad349). One switch per
    /// method; a deny or revoke needs none.
    public nonisolated enum GestureRule: Sendable {
        /// Every frame of the method (the user pressed send, picked a mode or an option).
        case always
        /// `acp.trust.set` that trusts (`level` other than `untrusted` or `unknown`).
        case whenTrusting
        /// `_acpmux/permission_respond` whose option is not a known deny.
        case whenOptionAllows
        /// `_acpmux/permission_group_respond` whose `decision` is not `deny`.
        case whenDecisionAllows
    }

    public static let gestureRules: [String: GestureRule] = [
        "session/prompt": .always,
        // Every value until the host has a list of the permissive ones (bypass, auto-approve, yolo).
        "session/set_mode": .always,
        "session/set_config_option": .always,
        "acp.trust.set": .whenTrusting,
        "_acpmux/permission_respond": .whenOptionAllows,
        "_acpmux/permission_group_respond": .whenDecisionAllows,
        // _acpmux/permission_chat_revoke revokes: no gesture.
    ]

    /// Whether `text` (a page frame the allowlist passed) grants and needs a gesture.
    /// Parsed every time: a substring test would miss an escaped method name.
    public static func needsGesture(_ text: String, options: AcpmuxPermissionOptions) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let method = object["method"] as? String, let rule = gestureRules[method] else { return false }
        let params = object["params"] as? [String: Any] ?? [:]
        switch rule {
        case .always:
            return true
        case .whenTrusting:
            let level = params["level"] as? String
            return level != "untrusted" && level != "unknown"
        case .whenOptionAllows:
            guard let permission = params["permissionId"] as? String, let option = params["optionId"] as? String else { return true }
            return !options.isDeny(permissionId: permission, optionId: option)
        case .whenDecisionAllows:
            return params["decision"] as? String != "deny"
        }
    }

    /// Where a frame carries the ticket of a gesture reserved at its pick (`params._meta.cmuxGesture`).
    public static let gestureTicketKey = "cmuxGesture"

    /// The frame's gesture ticket, the frame without it (the daemon never sees it), and whether
    /// its `_meta` held anything besides the ticket (R1: a redeeming frame may carry nothing else).
    static func takeGestureTicket(_ text: String) -> (text: String, ticket: String?, otherMeta: Bool) {
        // Parsed every time: an escaped key must still be stripped before the daemon.
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var params = object["params"] as? [String: Any], var meta = params["_meta"] as? [String: Any],
              let value = meta.removeValue(forKey: gestureTicketKey) else { return (text, nil, false) }
        let otherMeta = !meta.isEmpty
        if meta.isEmpty { params.removeValue(forKey: "_meta") } else { params["_meta"] = meta }
        object["params"] = params
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return (text, nil, otherMeta)
        }
        return (String(decoding: data, as: UTF8.self), value as? String ?? "", otherMeta)
    }

    /// The two methods that set a mode or an option; every other method may carry no mode field (P1).
    static let settingMethods: Set<String> = ["session/set_mode", "session/set_config_option"]

    /// What a session/set_mode or session/set_config_option asks for: set_mode is the `mode`
    /// option. `value` is nil when it is not a string (the daemon then gives no `asks`).
    static func requestedSetting(_ object: [String: Any]?) -> (sessionId: String?, configId: String, value: String?)? {
        guard let object, let params = object["params"] as? [String: Any] else { return nil }
        switch object["method"] as? String {
        case "session/set_mode":
            return (params["sessionId"] as? String, "mode", params["modeId"] as? String)
        case "session/set_config_option":
            return (params["sessionId"] as? String, params["configId"] as? String ?? "", params["value"] as? String)
        default:
            return nil
        }
    }

    /// The fail-closed rule (P1) while the daemon gives no mode fields: each method's params, and
    /// its `_meta.acpmux` keys, exactly as the pane sends them (`webviews/src/agent-session/acpmux`).
    /// This is the pane's param schema, not a mode list: with the daemon's `modeFields`, the rule
    /// is those fields instead. set_mode and set_config_option are not here (they meet the sheet).
    static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [
        "initialize": (["protocolVersion", "clientInfo", "clientCapabilities"], []),
        "session/new": (["cwd", "mcpServers", "_meta"], ["harness", "adopt", "peer"]),
        "session/prompt": (["sessionId", "prompt", "_meta"], ["promptId"]),
        "session/set_model": (["sessionId", "modelId"], []),
        "session/cancel": (["sessionId"], []),
        "_acpmux/watch": (["enabled"], []),
        "_acpmux/events": (["sessionId", "afterSeq", "beforeSeq", "limit", "kinds"], []),
        "_acpmux/attach": (["sessionId", "limit", "kinds", "eventStream"], []),
        "_acpmux/detach": (["sessionId"], []),
        "_acpmux/warm": (["sessionIds", "limit"], []),
        "_acpmux/kill": (["sessionId", "purge"], []),
        "_acpmux/prewarm": (["harness", "cwd"], []),
        "_acpmux/harnesses": ([], []),
        "_acpmux/models": ([], []),
        "_acpmux/permission_respond": (["sessionId", "permissionId", "optionId"], []),
        "_acpmux/handoff_prepare": (["sessionId", "harness", "handoffKey"], []),
        "_acpmux/handoff_get": (["sessionId", "handoffId"], []),
        "_acpmux/handoff_draft": (["handoffId", "revision", "draftKey", "capsule", "checkpoint"], []),
        "_acpmux/handoff_start": (["handoffId", "revision", "promptId", "capsule", "checkpoint"], []),
        "_acpmux/handoff_discard": (["handoffId"], []),
        "_acpmux/permission_groups": (["sessionId"], []),
        "_acpmux/permission_group_respond": (["sessionId", "groupId", "revision", "decisionKey", "decision"], []),
        "_acpmux/permission_chat_revoke": (["sessionId"], []),
        "acp.session.fork": (["sessionId", "throughSeq"], []),
        "acp.trust.get": (["cwd"], []),
        "acp.trust.set": (["cwd", "level"], []),
    ]

    /// P1: whether a page frame of a method other than set_mode and set_config_option names a
    /// mode field in its params or its `_meta.acpmux`. With the daemon's `modeFields`, any of
    /// those; without them (nil), any field outside the method's ``knownParams``.
    static func carriesModeField(_ object: [String: Any]?, modeFields: Set<String>?) -> Bool {
        guard let object, let method = object["method"] as? String, !settingMethods.contains(method) else { return false }
        guard let rawParams = object["params"] else { return false }
        guard let params = rawParams as? [String: Any] else { return true }
        let meta = params["_meta"] as? [String: Any]
        let acpmux = meta?["acpmux"] as? [String: Any] ?? [:]
        if let modeFields {
            return params.keys.contains(where: modeFields.contains) || acpmux.keys.contains(where: modeFields.contains)
        }
        guard let known = knownParams[method] else { return !params.isEmpty }
        if params.keys.contains(where: { !known.params.contains($0) }) { return true }
        if meta?["acpmux"] != nil, !(meta?["acpmux"] is [String: Any]) { return true }
        return acpmux.keys.contains(where: { !known.acpmux.contains($0) })
    }

    /// A frame's method and raw JSON-RPC id, for a refusal.
    static func identity(_ text: String) -> (method: String?, id: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return (nil, nil) }
        return (object["method"] as? String, object["id"].flatMap(rawID))
    }

    /// The key whose entries ({command, args, env}) a harness spawns.
    public static let serversKey = "mcpServers"

    /// Whether `value` holds a non-empty `mcpServers` (or one that is not a list) at any depth.
    static func carriesServers(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, inner) in object {
                if key == serversKey {
                    guard let list = inner as? [Any], list.isEmpty else { return true }
                } else if carriesServers(inner) {
                    return true
                }
            }
        } else if let list = value as? [Any] {
            return list.contains(where: carriesServers)
        }
        return false
    }

    /// A JSON-RPC id (number or string) as raw JSON.
    static func rawID(_ value: Any) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        if let string = value as? String,
           let data = try? JSONSerialization.data(withJSONObject: [string]) {
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return nil
    }
}
