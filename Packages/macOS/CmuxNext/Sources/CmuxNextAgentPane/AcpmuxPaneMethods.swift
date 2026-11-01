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
        // acpmux extensions (direct.ts). `_acpmux/attachment` reads a sent prompt's image by content hash.
        "_acpmux/watch", "_acpmux/events", "_acpmux/attachment", "_acpmux/attach", "_acpmux/detach", "_acpmux/view", "_acpmux/typing", "_acpmux/warm",
        // The session list's later pages (sessionPages.ts, cx-2lv1k): the same summaries watch answers,
        // read by cursor after watch's first page.
        "_acpmux/sessions",
        // A peer chat drawn from this Mac's copy while its machine is down (direct.ts drawPeerCopy,
        // peerCopy.ts; acpmux hub/peer_snapshot/read.rs). A read like `_acpmux/events`, before the
        // attach that brings the chat into scope, so not session-scoped; acpmux answers it to this
        // Mac's app and unix socket only. Only `sessionId` (``knownParams``): never `host`, which
        // would name any peer's session by its own id.
        "_acpmux/peer_snapshot",
        // Retry a configured peer after the offline copy's Reconnect action (direct.ts). This
        // names a peer machine, never a session, and waits for the daemon's doctor result.
        "_acpmux/peer_reconnect",
        // A failed subagent's, sub-session's or turn's Retry (subagents/retryState.ts runRetry,
        // direct.ts retry; acpmux server/agent_messages.rs): acpmux runs the failed turn again, or
        // resumes the failed subagent, now. No gesture (``gestureRules``): it sends nothing new, only
        // what acpmux already retries on its own after a transient failure, and the click's grant
        // stays for runRetry's fallback send to a daemon without the method. A sub-session's names
        // the child chat, which the click's scope credit brings in (``sourceScoped``). Only `sessionId` and `subagentId` (``knownParams``): never `_meta`,
        // which carries acpmux's control and trust-gate marks.
        "_acpmux/retry",
        "_acpmux/kill", "_acpmux/prewarm", "_acpmux/harnesses", "_acpmux/models", "_acpmux/permission_respond",
        // Take Over a View Only chat (direct.ts takeOver): the chat runs the conversation from then on.
        "_acpmux/watch_take_over",
        // Read-only, and its reply is filtered to ``replyShapes`` (ad349).
        "_acpmux/status", "_acpmux/draft_get",
        // Session-scoped draft writes are kept separate from the filtered replies above.
        "_acpmux/draft_set",
        // The thread minimap's prompt bookmarks of a chat in the pane's scope (direct.ts
        // readBookmarks, setBookmark): a seq and a flag, kept in acpmux's session meta.
        "_acpmux/bookmark_get", "_acpmux/bookmark_set",
        // Withdraw or change a queued prompt of a session in the pane's scope (direct.ts
        // removeQueued, editQueued).
        "_acpmux/queue_remove", "_acpmux/queue_edit",
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
        // The private secret card's answer to an agent's request_secret (SecretCard.tsx, cx-ncc.42):
        // the value goes to acpmux, which keeps it in memory and gives the agent a one-use ref. The
        // transport never logs a frame, so the value stays out of the host's logs.
        "_acpmux/secret_submit",
        // The chat menu's Archive / Unarchive and Mark as Unread of a session in the pane's scope
        // (direct.ts archive, markUnread; cx-jlzsf). `_acpmux/archive` sets or removes only the
        // `archived` tag: never `_acpmux/tag`, which may set any tag (the handoff target among
        // them). The app's tab close stays a host call (`pane.action closeTab`).
        "_acpmux/archive", "_acpmux/markUnread",
        // This Mac's agent CLI health for the chat notice and the Harnesses page (direct.ts
        // harnessHealth, cx-jlzsf): `refresh` runs the configured harnesses' version and sign-in
        // checks (and the auto-updates the person opted into), as acpmux does every few hours;
        // `rescan` has acpmux look on PATH and in its profiles again first (after an install from
        // the page); never `checkLatest` or `autoUpdate` (that choice turns updates on).
        "_acpmux/harness/health",
        // New side chat (direct.ts markSide, cx-jlzsf): tags the fork the pane made (in its scope)
        // `side` with its chat; only that tag, never `_acpmux/tag`.
        "_acpmux/side",
        // `/btw` (direct.ts btw): a read-only `side` session beside a chat in scope whose first prompt is the
        // question, so it runs a turn; its reply's session becomes the pane's (``AcpmuxPaneSessions/starting``).
        "_acpmux/btw",
        // Dismiss or Start on a chat's session offer chip (direct.ts dismissOffer, startOffer;
        // cx-807da): acpmux records the answer; Start names the child chat the pane just made.
        "_acpmux/offer_respond",
        // The mode acpmux would start a new chat on a harness in (direct.ts startMode, cx-wx93i),
        // which a pending chat's access chip names. Read only.
        "_acpmux/start_mode",
        // Stop a running Claude subagent or workflow of a chat in the pane's scope (direct.ts
        // stopSubagent, cx-liswe): acpmux sends Claude's stop_task for the task it already holds
        // for that child (claude_stdio/workflows.rs). It stops work like `_acpmux/kill`, so no
        // gesture; caller params never reach Claude.
        "_acpmux/subagent_stop", "_acpmux/subagent_transcript",
        // Page a chat's older turns in from its Claude Code transcript, past the newest page its log
        // was seeded with (direct.ts fetchNativeOlder; acpmux hub/native_history.rs). A read of the
        // pane's own chat: `before` is a byte cursor acpmux gave, never a path.
        "_acpmux/native_history",
        // Resume a paused agent pair of a chat in the pane's scope (the pause row's Resume; acpmux
        // hub/agent_pairs.rs): delivers the messages the two agents already sent and the guard held.
        // `peerSessionId` only picks one of that chat's paused pairs; acpmux resumes no pair the
        // chat is not in, and only for a connection that proved the person key (hub/person.rs).
        "_acpmux/agent_pair_resume",
        // Take over a chat its manager runs, or hand it back: only the chat in scope, and acpmux
        // takes it only from a connection that proved the person key (hub/agent_hold.rs).
        "_acpmux/agent_hold",
        // Reply in place to another agent's message as the chat the pane shows (direct.ts reply,
        // IncomingMessageCard.tsx): acpmux checks it and answers it signed, prompting nothing, and
        // the host sends it on as that chat's cmux agent message (``AgentPaneAgentReply``).
        "_acpmux/app_reply",
        // A chat's background processes (direct.ts listProcesses, tailProcess; the Inspector and an
        // opened background task note): read only, like `_acpmux/events`. acpmux serves them only to
        // this Mac's clients (server/processes.rs).
        "_acpmux/process/list", "_acpmux/process/tail",
        // Stop one (direct.ts killProcess) or send a chat's running work to the background (Ctrl-B,
        // backgroundWork) of a chat in the pane's scope: they stop or move work like `_acpmux/kill`,
        // so no gesture. A kill names its chat; acpmux stops only that chat's process.
        "_acpmux/process/kill", "_acpmux/process/background",
        // The composer's Account menu (direct.ts routes, setChatRoute): read the routes, and pick
        // one for a chat in the pane's scope. Adding or changing a route stays the unix socket's.
        "_acpmux/route/list", "_acpmux/chat/route.set",
        // The composer's sign-in check before a turn (direct.ts sessionAuth, sessionAuth.ts): read
        // only. It names its chat (`sessionId`, in the pane's scope) or a new chat's `target` (a
        // harness, and optionally its host and route), never another chat.
        "_acpmux/session/auth",
        // The Inspector's running-limit stepper (direct.ts setRunningLimit): how many of a chat's
        // sub-sessions in the pane's scope run a turn at once, or back to the inherited limit
        // (`null`). Only `maxRunning`: it starts nothing new and widens no permission (each child already
        // runs under its parent's policy), so no gesture; acpmux takes it only from a connection that
        // proved the person key (hub/subsessions.rs, `set_subsession_limits`).
        "_acpmux/subsession/limits",
        // Reconnect a failed MCP server of a chat in the pane's scope (direct.ts reconnectMcp, the
        // Inspector's Connectors): acpmux sends Claude Code's mcp_reconnect for a server the chat
        // already lists, on its running process; it starts nothing and refuses other harnesses.
        "_acpmux/mcp/reconnect",
        // The forum's current rules for the rules card above the composer (direct.ts forumRules,
        // RulesNotice.tsx; acpmux server/forum.rs, hq#2570). Read only and without params: the
        // rules every agent on this Mac is told already. Posting, acking and retiring stay off the pane.
        "_acpmux/forum/rules",
        // Use tools in the summary's Sources + (direct.ts setTool, cx-thur3): turns one of a chat's
        // MCP servers off or on again for that chat only; acpmux restarts its Claude Code and
        // resumes it (now, after the running turn, or at its next start).
        "_acpmux/set_tools",
    ]

    /// Notifications (no `id`).
    public static let notifications: Set<String> = ["session/cancel"]

    /// The top-level keys of a page frame (direct.ts sends no others).
    static let frameKeys: Set<String> = ["jsonrpc", "id", "method", "params"]

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
        // Only the keys the pane sends (cx-6o0): a `result` or `error` would make a request read as
        // a response, and the daemon might act on any other key it knows.
        guard Set(object.keys).isSubset(of: frameKeys) else { return refuse(.invalidFrame, object["method"] as? String, id) }
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

    /// The first frame with the LocalApp token in `_meta.acpmux` (the host's own token; the page
    /// never sees it). Any `personKey` the page put there is removed: the key never crosses the
    /// socket (cx-fcaq); the host proves it after this frame (``AgentPaneTransport``).
    static func withLocalAppToken(_ object: [String: Any], _ token: String) -> [String: Any] {
        var object = object
        var params = object["params"] as? [String: Any] ?? [:]
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        acpmux["localAppToken"] = token
        acpmux["personKey"] = nil
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
        "_acpmux/kill", "_acpmux/draft_get", "_acpmux/draft_set", "_acpmux/bookmark_get", "_acpmux/bookmark_set", "_acpmux/queue_remove", "_acpmux/queue_edit", "_acpmux/permission_respond", "_acpmux/permission_group_respond", "_acpmux/permission_chat_revoke",
        "_acpmux/secret_submit", "_acpmux/archive", "_acpmux/markUnread", "_acpmux/side", "_acpmux/btw",
        "_acpmux/offer_respond", "_acpmux/subagent_stop", "_acpmux/subagent_transcript", "_acpmux/native_history", "_acpmux/agent_pair_resume", "_acpmux/agent_hold", "_acpmux/app_reply",
        "_acpmux/watch_take_over",
        "_acpmux/process/kill", "_acpmux/process/background", "_acpmux/chat/route.set", "_acpmux/set_tools",
        "_acpmux/mcp/reconnect", "_acpmux/subsession/limits",
    ]

    /// Params beside `sessionId` that name a session, which must be in the pane's scope too: New
    /// side chat names the chat it is beside (cx-jlzsf).
    public static let scopedSessionParams: [String: Set<String>] = ["_acpmux/side": ["chat"]]

    /// Params beside `sessionId` that may name a session: none is fine, a named one (even `null`)
    /// must be a string in the pane's scope. Only an accepted offer names its child chat (the one
    /// the pane just started); a dismissed one names none. `_acpmux/side` always names its chat.
    public static let optionalScopedSessionParams: [String: Set<String>] = ["_acpmux/offer_respond": ["childSessionId"]]

    /// The folder trust question may name its chat (`sessionId`, so acpmux asks the chat's peer):
    /// a named session must be in the pane's scope (``sessionScoped``'s rule); none is fine.
    /// The sign-in check names a chat (`sessionId`) or only a new chat's `target`: a named one must
    /// be in the pane's scope too.
    public static let optionallySessionScoped: Set<String> = ["acp.trust.get", "acp.trust.set", "_acpmux/session/auth"]

    /// The methods that copy a session's content into a new session the pane then controls: a
    /// fork, and the handoff steps (prepare captures the source and makes the target, draft edits
    /// what it carries, start sends it, discard closes the target). From a session in the pane's
    /// scope they keep the rules above; from any other they use the click's scope credit, the same
    /// as an attach that brings a session in (``AgentPaneUserGestures/consumeScope()``). The fork
    /// and prepare name the source (`sessionId`); the others name the handoff (`handoffId`), whose
    /// source the relay reads off the daemon's handoff records (``AcpmuxPaneSessions``).
    /// `_acpmux/handoff_get` only reads a record, like the other reads of a read-only view.
    /// `_acpmux/retry` follows the same rule without copying anything: a Retry on a sub-session's
    /// card names that child chat, which the pane shows only as a card, so from outside the scope it
    /// takes the click's scope credit, as an attach of the child would; that attach would let the
    /// same click send it a prompt, which grants more than a Retry of its failed turn.
    public static let sourceScoped: Set<String> = [
        "acp.session.fork", "_acpmux/handoff_prepare", "_acpmux/handoff_draft", "_acpmux/handoff_start",
        "_acpmux/handoff_discard", "_acpmux/retry",
    ]

    /// The error frame that answers a refused request, as the daemon would answer an unknown one.
    /// `rootRequested` stays in the frame the Rust policy shares; this host no longer offers to add
    /// a refused folder as a root, so it never sets it. `detail`: acpmux's own reason (a refused
    /// Enable harness prompt), shown by the page; `reason`: why, as a code the page words.
    public static func refusal(requestID: String, error: AgentPaneTransportError, method: String?, rootRequested: Bool = false,
                               detail: String? = nil, reason: String? = nil) -> String {
        var data: [String: Any] = ["code": error.rawValue, "origin": "native"]
        if let method { data["method"] = method }
        if let detail, !detail.isEmpty { data["detail"] = String(detail.prefix(1000)) }
        if let reason { data["reason"] = reason }
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
        // A side session's question is its first prompt.
        "_acpmux/btw": .always,
        // Every value until the host has a list of the permissive ones (bypass, auto-approve, yolo).
        "session/set_mode": .always,
        "session/set_config_option": .always,
        "acp.trust.set": .whenTrusting,
        // The page's click opens the native sheet; the sheet's Enable is the second gesture.
        "_acpmux/harness_enable": .always,
        "_acpmux/permission_respond": .whenOptionAllows,
        "_acpmux/permission_group_respond": .whenDecisionAllows,
        // The card's Provide hands over a secret (its Decline is a click too).
        "_acpmux/secret_submit": .always,
        // Resume runs turns: the held messages go to both chats of the pair.
        "_acpmux/agent_pair_resume": .always,
        // Hand back delivers held messages, which runs turns.
        "_acpmux/agent_hold": .always,
        "_acpmux/app_reply": .always,
        // _acpmux/permission_chat_revoke revokes: no gesture.
        // _acpmux/offer_respond declines, or links the page's own new chat: no gesture (the work
        // Start begins is its session/prompt, which has one).
        // _acpmux/retry: no gesture. It runs again only the turn or subagent that failed, which acpmux
        // retries on its own anyway; the click's grant stays for runRetry's fallback (the prompt
        // sent again, or the ask to the chat's agent, when the daemon lacks the method).
        // _acpmux/set_tools: no gesture. It only turns off, or back on, an MCP server the chat
        // already had from the person's own config; it adds none.
    ]

    /// Whether a granting frame of `method` may use the current gesture: a permission allow needs
    /// the person's fresh click or permission shortcut, never a typing gesture (cx-ocdz).
    @MainActor static func answerAllowed(_ method: String?, _ gestures: AgentPaneUserGestures) -> Bool {
        let answers = method == "_acpmux/permission_respond" || method == "_acpmux/permission_group_respond"
        return !answers || gestures.hasFreshAnswerGesture
    }

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

    /// Strip untrusted block metadata at every depth, retaining only a top-level upload reference.
    /// The daemon validates that the finished upload belongs to this chat. Request params._meta
    /// stays; nil means the frame is unchanged.
    static func strippingPromptMeta(_ object: [String: Any]?) -> [String: Any]? {
        guard var object, object["method"] as? String == "session/prompt", var params = object["params"] as? [String: Any],
              let prompt = params["prompt"] as? [Any] else { return nil }
        var stripped = false
        func strip(_ value: Any, acceptsUpload: Bool = false) -> Any {
            if var dictionary = value as? [String: Any] {
                let upload = acceptsUpload ? promptUploadMeta(dictionary) : nil
                if dictionary.removeValue(forKey: "_meta") != nil { stripped = true }
                for (key, child) in dictionary where child is [String: Any] || child is [Any] { dictionary[key] = strip(child) }
                if let upload { dictionary["_meta"] = upload }
                return dictionary
            }
            if let list = value as? [Any] { return list.map { strip($0) } }
            return value
        }
        let blocks = prompt.map { strip($0, acceptsUpload: true) }
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
