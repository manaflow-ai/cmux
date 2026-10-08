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
nonisolated enum AcpmuxPaneMethods {
    /// The first frame of every connection, and only the first.
    public static let initialize = "initialize"

    /// Requests (`id` present).
    public static let requests: Set<String> = [
        // Sessions (direct.ts).
        "session/new", "session/prompt", "session/set_model", "session/set_mode", "session/set_config_option",
        // acpmux extensions (direct.ts).
        "_acpmux/watch", "_acpmux/events", "_acpmux/attach", "_acpmux/detach", "_acpmux/warm",
        "_acpmux/kill", "_acpmux/prewarm", "_acpmux/harnesses", "_acpmux/models", "_acpmux/permission_respond",
        // Read-only, and its reply is filtered to ``replyShapes`` (ad349).
        "_acpmux/status", "_acpmux/draft_get",
        // Session-scoped draft writes are kept separate from the filtered replies above.
        "_acpmux/draft_set",
        // Hand-off (handoff/protocol.ts HANDOFF_OPS).
        "_acpmux/handoff_prepare", "_acpmux/handoff_get", "_acpmux/handoff_draft", "_acpmux/handoff_start",
        "_acpmux/handoff_discard",
        // Grouped permissions (permissions/protocol.ts PERMISSION_GROUP_OPS).
        "_acpmux/permission_groups", "_acpmux/permission_group_respond", "_acpmux/permission_chat_revoke",
        // Fork (operations.ts FORK_OP) and folder trust (direct.ts trustGet/trustSet).
        "acp.session.fork", "acp.trust.get", "acp.trust.set",
        // Enable a folder harness (direct.ts harnessEnable): the relay asks the user on its own
        // native sheet and adds the confirmed sha256 itself (``AgentPaneHarnessEnablePrompt``).
        "_acpmux/harness_enable",
    ]

    /// The shape of a reply the relay filters itself, without relying on the daemon's redaction.
    public nonisolated indirect enum ReplyShape: Sendable {
        case string
        case object([String: ReplyShape])
        case list(ReplyShape)
    }

    /// Replies filtered to the fields the pane renders; everything else is dropped, at every depth.
    /// `_acpmux/status`: the pane reads only `peers[].name` (direct.ts, after initialize).
    public static let replyShapes: [String: ReplyShape] = [
        "_acpmux/status": .object(["peers": .list(.object(["name": .string]))]),
    ]

    /// `value` cut to `shape`: nil when it does not fit (a list keeps only the items that fit).
    static func filtered(_ value: Any, to shape: ReplyShape) -> Any? {
        switch shape {
        case .string:
            return value as? String
        case .list(let item):
            return (value as? [Any])?.compactMap { filtered($0, to: item) }
        case .object(let fields):
            guard let object = value as? [String: Any] else { return nil }
            let kept = fields.compactMap { key, field in object[key].flatMap { filtered($0, to: field) }.map { (key, $0) } }
            // An object with none of its fields is dropped (a peer with no name renders nothing).
            return kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept)
        }
    }

    /// A reply to a filtered request, rebuilt with the page's id (raw JSON) and its filtered
    /// result. An error keeps only its code and message.
    static func filteredReply(_ object: [String: Any], shape: ReplyShape, pageID: String) -> String {
        let id = (try? JSONSerialization.jsonObject(with: Data(pageID.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error = object["error"] as? [String: Any] {
            reply["error"] = ["code": error["code"] as? Int ?? -32603, "message": error["message"] as? String ?? ""]
        } else {
            reply["result"] = object["result"].flatMap { filtered($0, to: shape) } ?? [String: Any]()
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

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
        switch decideFrame(text, isFirst: isFirst) {
        case .failure(let refusal): return refusal.decision
        case .success(let page):
            guard isFirst, let localAppToken else { return .send(text) }
            let object = withLocalAppToken(page, localAppToken)
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
                return .refuse(.invalidFrame, method: object["method"] as? String, requestID: object["id"].flatMap(rawID))
            }
            return .send(String(decoding: data, as: UTF8.self))
        }
    }

    /// A refused page frame, as an error value.
    public nonisolated struct Refusal: Error, Sendable {
        public var decision: Decision
    }

    /// The one parse of a page frame that every rule reads (ad349): the duplicate check before it,
    /// then the allowlist and C1. The rules read the page's own frame; the LocalApp token goes into
    /// the first frame after them (``withLocalAppToken(_:_:)``).
    static func decideFrame(_ text: String, isFirst: Bool) -> Result<[String: Any], Refusal> {
        func refuse(_ error: AgentPaneTransportError, _ method: String?, _ id: String?) -> Result<[String: Any], Refusal> {
            .failure(Refusal(decision: .refuse(error, method: method, requestID: id)))
        }
        guard text.utf8.count <= maximumFrameBytes else { return refuse(.frameTooLarge, nil, nil) }
        // Before any parse: Foundation would keep one of two duplicate keys, the daemon the other.
        switch AcpmuxJSONKeys.verdict(text) {
        case .clean: break
        case .malformed: return refuse(.invalidFrame, nil, nil)
        case .duplicate:
            let (method, id) = identity(text)
            return refuse(.duplicateKey, method, id)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { return refuse(.invalidFrame, nil, nil) }
        let id = object["id"].flatMap(rawID)
        guard let method = object["method"] as? String else { return refuse(.methodRefused, nil, nil) }
        // C1: no page frame may make the harness spawn a command.
        if let params = object["params"], carriesServers(params) { return refuse(.mcpServersRefused, method, id) }
        if isFirst {
            guard method == initialize, id != nil else { return refuse(.firstFrameNotInitialize, method, id) }
            return .success(object)
        }
        let allowed = id == nil ? notifications.contains(method) : requests.contains(method)
        return allowed ? .success(object) : refuse(.methodRefused, method, id)
    }

    /// The first frame with the LocalApp token in `_meta.acpmux` (the host's own key; the page
    /// never sees it).
    static func withLocalAppToken(_ object: [String: Any], _ token: String) -> [String: Any] {
        var object = object
        var params = object["params"] as? [String: Any] ?? [:]
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        acpmux["localAppToken"] = token
        meta["acpmux"] = acpmux
        params["_meta"] = meta
        object["params"] = params
        return object
    }

    /// The methods allowed only for a session this pane started or shows (``AcpmuxPaneSessions``):
    /// every frame that writes to a session. A session outside the pane's scope (a second attach on
    /// one click) is a read-only view, and the pane never sends anything to it.
    public static let sessionScoped: Set<String> = [
        "session/prompt", "session/set_mode", "session/set_config_option", "session/set_model", "session/cancel",
        "_acpmux/kill", "_acpmux/draft_get", "_acpmux/draft_set", "_acpmux/permission_respond", "_acpmux/permission_group_respond", "_acpmux/permission_chat_revoke",
    ]

    /// The folder trust question may name its chat (`sessionId`, so acpmux asks the chat's peer):
    /// a named session must be in the pane's scope (``sessionScoped``'s rule); none is fine.
    public static let optionallySessionScoped: Set<String> = ["acp.trust.get", "acp.trust.set"]

    /// The methods that copy a session's content into a new session the pane then controls: a
    /// fork, and the handoff steps (prepare captures the source and makes the target, draft edits
    /// what it carries, start sends it, discard closes the target). From a session in the pane's
    /// scope they keep the rules above; from any other they use the click's scope credit, the same
    /// as an attach that brings a session in (``AgentPaneUserGestures/consumeScope()``). The fork
    /// and prepare name the source (`sessionId`); the others name the handoff (`handoffId`), whose
    /// source the relay reads off the daemon's handoff records (``AcpmuxPaneSessions``).
    /// `_acpmux/handoff_get` only reads a record, like the other reads of a read-only view.
    public static let sourceScoped: Set<String> = [
        "acp.session.fork", "_acpmux/handoff_prepare", "_acpmux/handoff_draft", "_acpmux/handoff_start",
        "_acpmux/handoff_discard",
    ]

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
        // The page's click opens the native sheet; the sheet's Enable is the second gesture.
        "_acpmux/harness_enable": .always,
        "_acpmux/permission_respond": .whenOptionAllows,
        "_acpmux/permission_group_respond": .whenDecisionAllows,
        // _acpmux/permission_chat_revoke revokes: no gesture.
    ]

    /// Whether `text` (a page frame the allowlist passed) grants and needs a gesture.
    /// Parsed every time: a substring test would miss an escaped method name.
    public static func needsGesture(_ text: String, options: AcpmuxPermissionOptions) -> Bool {
        needsGesture((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], options: options)
    }

    static func needsGesture(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> Bool {
        guard let object, let method = object["method"] as? String, let rule = gestureRules[method] else { return false }
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

    /// A session/prompt with every `_meta` inside its prompt blocks removed, at any depth (a block's
    /// own, a nested resource's, annotations'); nil when there is none (the frame goes unchanged).
    /// The request's own `params._meta` stays. Adapters read no block `_meta` today; a future one
    /// could, and the relay cannot check what it would do with it.
    static func strippingPromptMeta(_ object: [String: Any]?) -> [String: Any]? {
        guard var object, object["method"] as? String == "session/prompt", var params = object["params"] as? [String: Any],
              let prompt = params["prompt"] as? [Any] else { return nil }
        var stripped = false
        func strip(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                if dictionary.removeValue(forKey: "_meta") != nil { stripped = true }
                for (key, child) in dictionary where child is [String: Any] || child is [Any] { dictionary[key] = strip(child) }
                return dictionary
            }
            if let list = value as? [Any] { return list.map(strip) }
            return value
        }
        let blocks = prompt.map(strip)
        guard stripped else { return nil }
        params["prompt"] = blocks
        object["params"] = params
        return object
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
