import Foundation

/// The params rule (P1) of ``AcpmuxPaneMethods``: each method's own param schema.
nonisolated extension AcpmuxPaneMethods {
    /// The params rule (P1), on every path: each method's top-level params and `_meta.acpmux` keys,
    /// exactly as the pane sends them (`webviews/src/agent-session/acpmux`). This is the pane's own
    /// param schema, not a mode list. The daemon's `modeFields` are an extra deny inside it.
    static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [
        "initialize": (["protocolVersion", "clientInfo", "clientCapabilities"], []),
        // `noProject` is the pane's own (Do not work in a project): AcpmuxPathPolicy reads and strips it.
        // Never `workspaceId`: the host adds the pane's own after this rule (AcpmuxPathPolicy+Workspace).
        // `model`: a chat on another machine starts on the model the page showed (direct.ts
        // newSessionParams); one model id only (``isModelID(_:)``).
        "session/new": (["cwd", "mcpServers", "_meta"], ["harness", "adopt", "peer", "noProject", "model"]),
        // `context`: a chat's workspace context on its first prompt (cx-ihyx2); acpmux sends it to the
        // agent and keeps it out of the transcript text. `surface`: the place a prompt was typed
        // (labs.previewFeatures; acpmux hub/composers.rs, cmuxterm-hq#2580). No `provenance`: a reply
        // in place is `_acpmux/app_reply`, never a prompt (acpmux refuses one from the app too).
        // `inlineParts`: display descriptors for the prompt's attachment blocks. The daemon
        // validates them against those blocks and keeps them out of the agent's request.
        "session/prompt": (["sessionId", "prompt", "_meta"], ["promptId", "steer", "interrupt", "context", "surface", "inlineParts"]),
        "session/set_model": (["sessionId", "modelId"], []),
        "session/cancel": (["sessionId"], []),
        // `limit`: the newest page of the session list, the rest by `_acpmux/sessions` `cursor` (cx-2lv1k).
        "_acpmux/watch": (["enabled", "limit"], []),
        // `usage`: each chat's usage read first (SessionSummary.usageStats), for Session Info's Usage.
        "_acpmux/sessions": (["limit", "cursor", "usage"], []),
        // `maxBytes`: the most one page downloads, opening a chat or paging older turns in (cx-2lv1k).
        "_acpmux/events": (["sessionId", "afterSeq", "beforeSeq", "limit", "maxBytes", "kinds"], []),
        "_acpmux/attachment": (["sessionId", "id"], []),
        // The pane names the listed chat (its id or `HOST/id`) and takes acpmux's default bounds:
        // no `host`, `limit` or `maxBytes`.
        "_acpmux/peer_snapshot": (["sessionId"], []),
        // The peer machine to retry; `wait` asks the daemon to include the settled doctor result.
        "_acpmux/peer_reconnect": (["name", "wait"], []),
        // runRetry sends `{sessionId, subagentId}` for a subagent, `{sessionId}` for a sub-session
        // (its own id) or the chat's own turn.
        "_acpmux/retry": (["sessionId", "subagentId"], []),
        // `visible`: whether the pane shows the chat; acpmux owns unread from it (cx-n8ou).
        "_acpmux/attach": (["sessionId", "limit", "maxBytes", "kinds", "eventStream", "visible", "waitLogs"], []),
        "_acpmux/detach": (["sessionId"], []),
        "_acpmux/view": (["sessionId", "visible"], []),
        // Whether this pane types in a shared chat, never its text (multiplayer/presenceClient.ts).
        "_acpmux/typing": (["sessionId", "on"], []),
        "_acpmux/warm": (["sessionIds", "limit"], []),
        "_acpmux/kill": (["sessionId", "purge"], []),
        // `ifLive`: `fork` or `open` once the person chose, for a chat still live in its own app.
        "_acpmux/watch_take_over": (["sessionId", "ifLive"], []),
        // Background processes (direct.ts listProcesses, tailProcess, killProcess, backgroundWork):
        // a kill names its chat, which must be the pane's, and acpmux stops only that chat's process.
        "_acpmux/process/list": (["sessionId"], []),
        "_acpmux/process/tail": (["processId", "maxBytes"], []),
        "_acpmux/process/kill": (["sessionId", "processId"], []),
        "_acpmux/process/background": (["sessionId", "toolCallId"], []),
        // The composer's Account menu (direct.ts routes, setChatRoute).
        "_acpmux/route/list": (["sessionId"], []),
        "_acpmux/chat/route.set": (["sessionId", "routeId", "when"], []),
        // The sign-in check (direct.ts sessionAuth): a chat in scope, or a new chat's `target`
        // ({harness, host?, routeId?}), and `refresh` to ask the harness now instead of its last answer.
        "_acpmux/session/auth": (["sessionId", "target", "refresh"], []),
        // The running-limit stepper: `maxRunning` only, never `maxChildren` or `maxDepth`.
        "_acpmux/subsession/limits": (["sessionId", "maxRunning"], []),
        // `server`: one of that chat's MCP servers by name; acpmux refuses a name the chat does not list.
        "_acpmux/mcp/reconnect": (["sessionId", "server"], []),
        // `release`: a new chat's typing prewarm taken back (cleared prompt, closed unsent; newChatPrewarm.ts).
        "_acpmux/prewarm": (["harness", "cwd", "release"], []),
        "_acpmux/start_mode": (["harness", "cwd"], []),
        // `cwd`: the chat folder whose folder harness profiles to list (checked like every cwd).
        "_acpmux/harnesses": (["cwd"], []),
        // `refresh`: the picker's Refresh models; acpmux probes its agents' model lists again. It
        // grants nothing (the same probes acpmux runs in the background), so no gesture rule.
        "_acpmux/models": (["refresh"], []),
        "_acpmux/status": ([], []),
        "_acpmux/peers": ([], []),
        "_acpmux/draft_get": (["sessionId"], []),
        "_acpmux/draft_set": (["sessionId", "text"], []),
        "_acpmux/inbox_thread": (["sessionId", "threadId"], []),
        "_acpmux/bookmark_get": (["sessionId"], []),
        "_acpmux/bookmark_set": (["sessionId", "seq", "bookmarked"], []),
        "_acpmux/queue_remove": (["sessionId", "promptId"], []),
        // `images`: an edit's kept image ids (acpmux attachment ids the queue lists); it names only
        // the prompt's own images, so it reaches nothing the chat does not already hold.
        "_acpmux/queue_edit": (["sessionId", "promptId", "op", "text", "images", "index"], []),
        // `_meta`: only the gesture ticket of the person's pick (cx-0q7o), never anything else.
        "_acpmux/permission_respond": (["sessionId", "permissionId", "optionId", "answers", "annotations", "_meta"], []),
        "_acpmux/handoff_prepare": (["sessionId", "harness", "handoffKey"], []),
        "_acpmux/handoff_get": (["sessionId", "handoffId"], []),
        "_acpmux/handoff_draft": (["handoffId", "revision", "draftKey", "capsule", "checkpoint"], []),
        "_acpmux/handoff_start": (["handoffId", "revision", "promptId", "capsule", "checkpoint"], []),
        "_acpmux/handoff_discard": (["handoffId"], []),
        "_acpmux/permission_groups": (["sessionId"], []),
        "_acpmux/permission_group_respond": (["sessionId", "groupId", "revision", "decisionKey", "decision"], []),
        "_acpmux/permission_chat_revoke": (["sessionId"], []),
        // No `value` declines the card.
        "_acpmux/secret_submit": (["sessionId", "secretId", "value"], []),
        "_acpmux/archive": (["sessionId", "archived"], []),
        "_acpmux/markUnread": (["sessionId"], []),
        "_acpmux/harness/health": (["refresh", "rescan"], []),
        "_acpmux/forum/rules": ([], []),
        "_acpmux/side": (["sessionId", "chat"], []),
        // `model`: the side session's model when the page names one; acpmux picks a fast one otherwise.
        "_acpmux/btw": (["sessionId", "question", "model", "inline"], []),
        "_acpmux/offer_respond": (["sessionId", "offerId", "outcome", "childSessionId"], []),
        // `subagentSessionId`: a child of that chat, which acpmux looks up in the chat's own map.
        "_acpmux/subagent_transcript": (["sessionId", "runId", "agentId", "before", "after", "limit"], []),
        // `before`: a `native_history` cursor, a byte offset into the chat's own transcript.
        "_acpmux/native_history": (["sessionId", "before", "mark"], []),
        "_acpmux/subagent_stop": (["sessionId", "subagentSessionId"], []),
        // `peerSessionId`: one of that chat's paused pairs, a selector only (acpmux checks the pair has the chat).
        "_acpmux/agent_pair_resume": (["sessionId", "peerSessionId"], []),
        "_acpmux/agent_hold": (["sessionId", "held"], []),
        // The pane's chat (`sessionId`) answers `replyTo` of `threadId`, which chat `to` sent it;
        // `replyId` keys it. No recipient, sender name or credential: acpmux signs it, the daemon
        // sends it to the message's sender (``AgentPaneAgentReply``).
        "_acpmux/app_reply": (["sessionId", "to", "replyTo", "threadId", "text", "replyId"], []),
        // `id`: the chat's tool row (`mcp:<server>`); `enabled`: on or off for this chat.
        "_acpmux/set_tools": (["sessionId", "id", "enabled"], []),
        // A Cloud chat's sign-in (cloudAgentLogin.ts): `agent` is `claude` or `codex`; `code` is
        // Claude's pasted code, `key` an API key, both kept out of every log; `sessionId` the chat.
        "_acpmux/agent_login/start": (["agent", "sessionId"], []),
        "_acpmux/agent_login/finish": (["loginId", "code", "sessionId"], []),
        "_acpmux/agent_login/api_key": (["agent", "key", "sessionId"], []),
        "_acpmux/agent_login/cancel": (["loginId", "sessionId"], []),
        // `live`: Fork Conversation's fork of the whole chat as it is now (acpmux `fork_through.rs`).
        "acp.session.fork": (["sessionId", "throughSeq", "live"], []),
        "acp.trust.get": (["cwd", "sessionId"], []),
        "acp.trust.set": (["cwd", "level", "sessionId"], []),
        // Never `sha256`: only the relay adds it, after the native sheet's Enable.
        "_acpmux/harness_enable": (["folder", "id"], []),
        // They meet the gesture rule and the sheet; their mode field is their purpose.
        "session/set_mode": (["sessionId", "modeId", "_meta"], []),
        "session/set_config_option": (["sessionId", "configId", "value", "_meta"], []),
    ]

    /// P1: whether a page frame breaks the params rule. On every method: a top-level param outside
    /// the method's ``knownParams``; a `_meta` that is not an object, or that holds a key other
    /// than `acpmux`; an `acpmux` key outside the method's list. On every method except set_mode and
    /// set_config_option, also a daemon `modeFields` name at the top of params or in `acpmux`.
    /// A set_mode or set_config_option with `cmuxGesture` in `_meta` redeems a ticket: its `_meta`
    /// is the gesture rule's (R1 refuses any other key there and spends the ticket).
    static func breaksParamsRule(_ object: [String: Any]?, modeFields: Set<String>?) -> Bool {
        guard let object, let method = object["method"] as? String, let rawParams = object["params"] else { return false }
        guard let params = rawParams as? [String: Any] else { return true }
        guard let known = knownParams[method] else { return !params.isEmpty }
        if params.keys.contains(where: { !known.params.contains($0) }) { return true }
        let setting = settingMethods.contains(method)
        let denied = setting ? [] : modeFields ?? []
        if params.keys.contains(where: denied.contains) { return true }
        guard let rawMeta = params["_meta"] else { return false }
        guard let meta = rawMeta as? [String: Any] else { return true }
        // A redeeming frame: R1 first (nothing but the ticket in _meta), then the gesture rule.
        if setting, meta["cmuxGesture"] != nil { return meta.keys.contains { $0 != "cmuxGesture" } }
        // A permission answer's `_meta` holds the pick's ticket and nothing else.
        if method == "_acpmux/permission_respond" { return Set(meta.keys) != [gestureTicketKey] }
        // A prompt held for the folder trust answer redeems its ticket beside its acpmux.promptId.
        if meta.keys.contains(where: { $0 != "acpmux" && !(method == "session/prompt" && $0 == gestureTicketKey) }) { return true }
        guard let rawAcpmux = meta["acpmux"] else { return false }
        guard let acpmux = rawAcpmux as? [String: Any] else { return true }
        if acpmux.keys.contains(where: { !known.acpmux.contains($0) || denied.contains($0) }) { return true }
        // A start's model is a spawn parameter (Claude Code's `--model`, `${model}` in a harness's
        // argv or env): one model id, never a flag or anything else.
        if method == "session/new", let model = acpmux["model"] { return !isModelID(model) }
        return false
    }

    /// The longest `_meta.acpmux.model` a start may carry, in bytes.
    static let maximumModelIDBytes = 256

    /// One model id as harnesses name them (`claude-opus-5-5[1m]`, `provider/model:tag`,
    /// `model@version`): 1 to ``maximumModelIDBytes`` ASCII letters, digits and `._-/:@[]+`, not
    /// starting with `-`. No whitespace, control, quote, shell or template character.
    static func isModelID(_ value: Any) -> Bool {
        guard let model = value as? String, !model.isEmpty, model.utf8.count <= maximumModelIDBytes,
              !model.hasPrefix("-") else { return false }
        return model.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
            default: "._-/:@[]+".utf8.contains(byte)
            }
        }
    }
}
