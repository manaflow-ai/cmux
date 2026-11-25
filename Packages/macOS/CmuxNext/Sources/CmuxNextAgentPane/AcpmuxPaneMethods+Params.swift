import Foundation

/// The params rule (P1) of ``AcpmuxPaneMethods``: each method's own param schema.
nonisolated extension AcpmuxPaneMethods {
    /// The params rule (P1), on every path: each method's top-level params and `_meta.acpmux` keys,
    /// exactly as the pane sends them (`webviews/src/agent-session/acpmux`). This is the pane's own
    /// param schema, not a mode list. The daemon's `modeFields` are an extra deny inside it.
    static let knownParams: [String: (params: Set<String>, acpmux: Set<String>)] = [
        // `peerRowBatches`: a peer's list comes as one `_acpmux/peer_rows_changed` (cmux#46563).
        // schemas/agent-pane/initialize-params.json lists every initialize the page sends; refused,
        // no chat connects at all (the pane reconnects every few seconds, ask-0e0d5a479b). An
        // acpmux key missing here is stripped, not refused (``strippingInitializeOptIns``); still
        // list each one the page sends, or the daemon never sees the opt-in.
        "initialize": (["protocolVersion", "clientInfo", "clientCapabilities", "_meta"], ["peerRowBatches"]),
        // `noProject` is the pane's own (Do not work in a project): AcpmuxPathPolicy reads and strips it.
        // Never `workspaceId`: the host adds the pane's own after this rule (AcpmuxPathPolicy+Workspace).
        // `model`: a chat on another machine starts on the model the page showed (direct.ts
        // newSessionParams); one model id only (``isModelID(_:)``). `additionalDirectories`: the folders
        // the chat sees beside its own (the composer's Add folder…, cmux#32811); AcpmuxPathPolicy checks
        // each as it checks `cwd`. `restricted`: a read-only chat in a folder the person declined
        // (Read-only here); acpmux keeps its policy and the folder's config off (hub/restricted.rs).
        // `autoPlace`: the person picked Auto, so with no room anywhere acpmux may wait for a machine
        // being added (hub/admission.rs); an explicit This Mac or machine never sends it.
        "session/new": (["cwd", "mcpServers", "additionalDirectories", "_meta"], ["harness", "adopt", "peer", "noProject", "model", "restricted", "autoPlace"]),
        "chat.fix_from_link": (["url", "cwd", "harness", "model", "_meta"], []),
        "chat.fix_from_link.prepare": (["url", "cwd", "harness", "model"], []),
        // `context`: a chat's workspace context on its first prompt (cx-ihyx2); acpmux sends it to the
        // agent and keeps it out of the transcript text. `surface`: the place a prompt was typed
        // (labs.previewFeatures; acpmux hub/composers.rs, cmuxterm-hq#2580). No `provenance`: a reply
        // in place is `_acpmux/app_reply`, never a prompt (acpmux refuses one from the app too).
        // `inlineParts`: display descriptors for the prompt's attachment blocks. The daemon
        // validates them against those blocks and keeps them out of the agent's request.
        // `promptSuggestion: "taken"`: the person sent the suggested next prompt (direct.ts, #34496);
        // acpmux only counts it taken for the suggestion gate (suggestion_gate.rs marked_taken).
        "session/prompt": (["sessionId", "prompt", "_meta"], ["promptId", "steer", "interrupt", "context", "surface", "inlineParts", "promptSuggestion"]),
        "session/set_model": (["sessionId", "modelId"], []),
        "session/cancel": (["sessionId"], []),
        // `limit`: the newest page of the session list, the rest by `_acpmux/sessions` `cursor` (cx-2lv1k).
        // `afterSeq`, `listEpoch`: a reconnect follows the list from the cursor it last read (#41889).
        "_acpmux/watch": (["enabled", "limit", "afterSeq", "listEpoch"], []),
        // `usage`: each chat's usage read first (SessionSummary.usageStats), for Session Info's Usage.
        "_acpmux/sessions": (["limit", "cursor", "usage"], []),
        // `known`: the digest of the usage answer the page holds; acpmux answers `unchanged` while it is current.
        "_acpmux/usage": (["known"], []),
        // `maxBytes`: the most one page downloads, opening a chat or paging older turns in (cx-2lv1k).
        // `promptIndex`: the prompt rail's index of every turn (direct.ts readPromptIndex; acpmux
        // hub/paging.rs prompt_index, #34273). Refused, the rail never learns a long chat's turns.
        // `subagent`: one subagent's own records, for its pane when the chat's page no longer holds
        // it (subagents/subagentOwnLog.ts; acpmux hub/paging.rs EventFilter::of_subagent).
        "_acpmux/events": (["sessionId", "afterSeq", "beforeSeq", "limit", "maxBytes", "kinds", "promptIndex", "subagent"], []),
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
        // `settled`: a cold open asks for acpmux's settled view (direct.ts sendAttach,
        // settled-attach-v1); refused, no chat opens once the daemon names it (#42185).
        // `hold`: a chat drawn from the row store attaches without a page (rows/holdKinds.ts,
        // attach-hold-v1); refused, the open failed and no new chat started (#42460).
        // `afterSeq`: a reconnect that holds the chat's rows asks only the records after them
        // (attachParams.ts plainAttach, forward attach, #47119); refused, every reconnect said "cmux
        // blocked opening this chat" over the composer (Leo, 2026-11-22).
        // `attending`: the reader's hand on a shown chat, apart from `visible` (on screen); `quietHidden`: the
        // page draws nothing while hidden, so acpmux leaves the agent's stream out until it shows (CMUX-571).
        // schemas/agent-pane/attach-params.json lists every key the page sends here.
        "_acpmux/attach": (["sessionId", "limit", "maxBytes", "kinds", "eventStream", "visible", "attending", "quietHidden", "waitLogs", "settled", "hold", "afterSeq"], []),
        "_acpmux/detach": (["sessionId"], []),
        "_acpmux/view": (["sessionId", "visible", "attending", "seenSeq", "cutoverSeq"], []),
        "_acpmux/seen": (["sessionId", "seq"], []),
        // Whether this pane types in a shared chat, never its text (multiplayer/presenceClient.ts).
        "_acpmux/typing": (["sessionId", "on"], []),
        "_acpmux/warm": (["sessionIds", "limit"], []),
        // `cancelFork`: Fork Conversation's Cancel takes back a fork nobody used, with the transcript
        // copy its agent made (direct.ts `takeBackFork`, acpmux hub/fork_cancel.rs); with
        // `cancelToken`, it stops the fork that token names while it is still being made.
        // `ifIdle`: Move to Terminal stops the chat only while no turn, prompt or tool call is open
        // (direct.ts `releaseToTerminal`, acpmux hub/stop_if_idle.rs); it only narrows a stop.
        "_acpmux/kill": (["sessionId", "purge", "cancelFork", "cancelToken", "ifIdle"], []),
        // `ifLive`: `fork` or `open` once the person chose, for a chat still live in its own app.
        "_acpmux/watch_take_over": (["sessionId", "ifLive"], []),
        // Background processes (direct.ts listProcesses, tailProcess, killProcess, backgroundWork):
        // a kill names its chat, which must be the pane's, and acpmux stops only that chat's process.
        // The page holds the running ones and the newest ended (`recent`, `endedWithin`) and the
        // processes of the calls its transcript shows (`calls`); a daemon without them is
        // read page by page (`limit`, then each page's `nextCursor` as `cursor`).
        "_acpmux/process/list": (["sessionId", "limit", "cursor", "recent", "endedWithin", "calls"], []),
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
        "_acpmux/race/start": (["parent", "prompt", "candidates", "reviewer"], []),
        "_acpmux/race/get": (["parent", "raceId"], []),
        "_acpmux/race/list": (["parent"], []),
        "_acpmux/race/cancel": (["parent", "raceId"], []),
        "_acpmux/race/stats": (["parent"], []),
        // `server`: one of that chat's MCP servers by name; acpmux refuses a name the chat does not list.
        "_acpmux/mcp/reconnect": (["sessionId", "server"], []),
        // `release`: a new chat's typing prewarm taken back (cleared prompt, closed unsent; newChatPrewarm.ts).
        "_acpmux/prewarm": (["harness", "cwd", "release"], []),
        "_acpmux/start_mode": (["harness", "cwd"], []),
        // New project (direct.ts newProject): the folder's name only, never a path or a root.
        "_acpmux/project_new": (["name"], []),
        // `cwd`: the chat folder whose folder harness profiles to list (checked like every cwd).
        // `_meta.acpmux.peer`: a new chat bound for another of the person's machines reads that
        // machine's agents (Austin, 2026-11-12; webviews machineHarnesses.ts). acpmux forwards it to
        // that peer with no caller params, from local and app connections only. One non-empty name.
        "_acpmux/harnesses": (["cwd", "_meta"], ["peer"]),
        // `refresh`: the picker's Refresh models; acpmux probes its agents' model lists again. It
        // grants nothing (the same probes acpmux runs in the background), so no gesture rule.
        // `localOnly`: this machine's lists only, without waiting on the peers (the picker's own read).
        "_acpmux/models": (["refresh", "localOnly"], []),
        "catalog.get": ([], []),
        "catalog.refresh": ([], []),
        // Only the live-tree read: `waitLogs: false` answers from the session list at once.
        "_acpmux/info": (["sessionId", "waitLogs", "includeLiveTree"], []),
        "_acpmux/status": ([], []),
        "_acpmux/peers": ([], []),
        // Which of the page's requests the daemon still runs (AcpmuxRequestIds.requestStateMethod).
        "_acpmux/request_state": ([], []),
        // The chat Inspector's Perf tab and page reporter (PerfPanel.tsx, perfReporter.ts; acpmux perf_watch.rs):
        // a default-off diagnostic that names no path and starts nothing; acpmux answers this Mac's app and
        // unix socket only. `op`: on, off, status, read (`after`, `limit`, `waitMs`), snapshot, budgets, or report (the
        // page's measurements: `page`, `windowMs`, `spans`, `renders`, `frames`, `layoutShifts`, `bytes`), frames, or tally (frameTally.ts: `bucketMs`, `gaps`).
        "_acpmux/perf": (["op", "after", "limit", "waitMs", "page", "windowMs", "spans", "renders", "frames", "layoutShifts", "bytes", "bucketMs", "gaps"], []),
        "_acpmux/host_overload": ([], []),
        // Placement names are local display labels; the optional source lets the page filter
        // targets for a chat without exposing a host URL or session identity.
        "_acpmux/move_targets": (["source", "sourceKind"], []),
        // `where`: "auto" (or "here"); `targets`: the places the page can start a chat on, each a
        // `place` name and its `headroom`, all data the page already holds (Cloud today).
        // `parent` ({machine, fork}) and `key`: the Cloud machine the starting chat runs on and
        // this start's key, for fork placement behind `cloud.autoCloud` (acpmux fork_place.rs).
        "_acpmux/place_chat": (["where", "targets", "parent", "key"], []),
        "_acpmux/draft_get": (["sessionId"], []),
        "_acpmux/draft_set": (["sessionId", "text"], []),
        "_acpmux/inbox_thread": (["sessionId", "threadId"], []),
        "_acpmux/bookmark_get": (["sessionId"], []),
        "_acpmux/turn_shots": (["sessionId", "turnId"], []),
        "_acpmux/bookmark_set": (["sessionId", "seq", "bookmarked"], []),
        "_acpmux/prompts_list": ([], []),
        "_acpmux/prompts_save": (["name", "text"], []),
        "_acpmux/prompts_delete": (["name"], []),
        "_acpmux/stash_list": (["chat"], []),
        "_acpmux/stash_push": (["chat", "text", "attachments", "replaces"], []),
        "_acpmux/stash_get": (["chat", "id"], []),
        "_acpmux/stash_drop": (["chat", "id"], []),
        "_acpmux/stash_move": (["chat", "to"], []),
        "_acpmux/queue_remove": (["sessionId", "promptId"], []),
        // `turnId` and `revision`: the queued incarnation and revision the owner saw (acpmux answers
        // `queue.stale` on another one; direct.ts answerHeld names both).
        "_acpmux/queue_approve": (["sessionId", "promptId", "turnId", "revision"], []),
        "_acpmux/queue_decline": (["sessionId", "promptId"], []),
        "_acpmux/queue_get": (["sessionId", "promptId"], []),
        // `images`: an edit's kept image ids (acpmux attachment ids the queue lists); it names only
        // the prompt's own images, so it reaches nothing the chat does not already hold.
        "_acpmux/queue_edit": (["sessionId", "promptId", "op", "text", "images", "index"], []),
        // `_meta`: only the gesture ticket of the person's pick (cx-0q7o), never anything else.
        "_acpmux/permission_respond": (["sessionId", "permissionId", "optionId", "answers", "annotations", "_meta"], []),
        // `_meta`: only the gesture ticket of the person's Build pick, as an answer's. No
        // `harnesses`: the pane builds with the chat's own harness, or it and the other of Claude
        // and Codex for a compare.
        "_acpmux/plan/build": (["sessionId", "permissionId", "target", "plan", "_meta"], []),
        "_acpmux/plan/compare": (["sessionId", "buildId"], []),
        "_acpmux/plan/keep": (["sessionId", "buildId", "keep"], []),
        "_acpmux/handoff_prepare": (["sessionId", "harness", "handoffKey"], []),
        "_acpmux/handoff_get": (["sessionId", "handoffId"], []),
        "_acpmux/handoff_draft": (["handoffId", "revision", "draftKey", "capsule", "checkpoint"], []),
        "_acpmux/handoff_start": (["handoffId", "revision", "promptId", "capsule", "checkpoint"], []),
        "_acpmux/handoff_discard": (["handoffId"], []),
        "_acpmux/permission_groups": (["sessionId"], []),
        "_acpmux/permission_group_respond": (["sessionId", "groupId", "revision", "decisionKey", "decision"], []),
        "_acpmux/permission_chat_revoke": (["sessionId"], []),
        // No `value` declines the card. `keepAs`: the card's "keep as key NAME", which acpmux stores in the key store.
        "_acpmux/secret_submit": (["sessionId", "secretId", "value", "keepAs"], []),
        // The preset approval card's answer only; a preset write (`set`, `clear`) never comes from the pane.
        "_acpmux/presets": (["name", "approveMode", "approveDigest", "sessionId"], []),
        "_acpmux/archive": (["sessionId", "archived"], []),
        "_acpmux/cold_archive": (["sessionId", "archived"], []),
        "_acpmux/prompt_coach": (["sessionId", "coachId"], []),
        "_acpmux/customize_run": (["run", "_meta"], []),
        // Auto (plans/cmux-next/auto-mode/DESIGN.md): `keepInCloud` only while the Cloud runs the chat.
        "_acpmux/auto_session/set": (["sessionId", "auto", "keepInCloud"], []),
        // `action`: show, apply or discard.
        "_acpmux/auto_session/leftover": (["sessionId", "action"], []),
        // The Cloud's events after seq `after`; `version`: the read the page speaks.
        "_acpmux/auto_session/transcript": (["sessionId", "after", "version"], []),
        "_acpmux/run_elsewhere/plan": (["sessionId", "command"], []),
        "_acpmux/run_elsewhere/start": (["sessionId", "command", "peer", "digest", "sendSecrets"], []),
        "_acpmux/bg/output": (["sessionId", "id", "fromByte", "maxBytes"], []), // maxBytes: bgTail, a finished task line's tail.
        "_acpmux/bg/stop": (["sessionId", "id"], []),
        "_acpmux/markUnread": (["sessionId"], []),
        "_acpmux/harness/health": (["refresh", "rescan"], []),
        "_acpmux/forum/rules": ([], []),
        "_acpmux/resolve": (["query"], []),
        "_acpmux/side": (["sessionId", "chat"], []),
        // The fork's boundary (`throughSeq`, or `live` for a working chat) and `/side`'s prompt.
        "_acpmux/side_chat": (["sessionId", "throughSeq", "live", "prompt"], []),
        // `model`: the side session's model when the page names one; acpmux picks a fast one otherwise.
        "_acpmux/btw": (["sessionId", "question", "model", "inline", "targetHarness"], []),
        "_acpmux/offer_respond": (["sessionId", "offerId", "outcome", "childSessionId"], []),
        // `accept` and `dismiss`: the offer's own one-line facts, which acpmux matches against it.
        "_acpmux/memory_resolve": (["sessionId", "offerId", "file", "accept", "dismiss"], []),
        "_acpmux/agent_home": (["sessionId"], []),
        // `accept` and `drop`: proposal ids from `_acpmux/agent_home`.
        "_acpmux/agent_home_resolve": (["sessionId", "accept", "drop"], []),
        "_acpmux/context": (["sessionId"], []),
        "_acpmux/ledger": (["since", "until", "limit", "groupBy"], []),
        "_acpmux/team_audit": (["since", "until", "groupBy", "format"], []),
        "_acpmux/review_queue": (["localOnly", "limit"], []),
        "_acpmux/review_verdict": (["prUrl", "sessionId", "verdict", "comment"], []),
        "_acpmux/audit": (["since", "until", "sessionId", "limit", "cursor"], []),
        // `text: null` removes the saved text; `partId`: a verified local preset prompt's id.
        "_acpmux/context_override": (["sessionId", "scope", "text", "partId"], []),
        // `subagentSessionId`: a child of that chat, which acpmux looks up in the chat's own map.
        "_acpmux/subagent_transcript": (["sessionId", "runId", "agentId", "before", "after", "limit"], []),
        // `ended`: how many ended subagents to list, at most 500.
        "_acpmux/subagents": (["sessionId", "ended"], []),
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
        "_acpmux/account/sign_in": (["family", "sessionId"], []),
        "_acpmux/account/sign_in.finish": (["loginId", "sessionId"], []),
        "_acpmux/account/sign_in.cancel": (["loginId", "sessionId"], []),
        // `live`: Fork Conversation's fork of the whole chat as it is now (acpmux `fork_through.rs`).
        // `cancelToken`: the name its Cancel stops it by (acpmux hub/fork_cancel.rs).
        "acp.session.fork": (["sessionId", "throughSeq", "live", "cancelToken", "harness", "model"], []),
        // `peer` names the machine that owns `cwd`; its folder is checked for shape only and
        // never canonicalized against this Mac's filesystem (the owning daemon checks it).
        "acp.trust.get": (["cwd", "sessionId", "peer"], []),
        "acp.trust.set": (["cwd", "level", "sessionId", "peer"], []),
        // Never `sha256`: only the relay adds it, after the native sheet's Enable.
        "_acpmux/harness_enable": (["folder", "id"], []),
        // They meet the gesture rule and the sheet; their mode field is their purpose.
        "session/set_mode": (["sessionId", "modeId", "_meta"], []),
        "session/set_config_option": (["sessionId", "configId", "value", "_meta"], []),
    ]

    /// P0, before the params rule: `object` with every key the method's lists do not name removed,
    /// and those keys' paths (`limit`, `_meta.other`, `_meta.acpmux.peerRowBatches`), sorted; nil
    /// when it names none. A page newer than this app may send a field the app has never heard of
    /// (cmux#46563 sent `initialize` `_meta.acpmux.peerRowBatches`, and refusing it refused every
    /// chat's open on a NIGHTLY, 737 times; cmux#42185 `settled` and #42460 `hold` did the same to
    /// every attach). Dropped, the field never reaches the daemon, which answers as it did before
    /// the field existed: what is sent is a part of the page's frame the params rule passes on its
    /// own, so the strip never grants more than a refusal would.
    ///
    /// It keeps what the params rule refuses on purpose, so the rule still refuses it: a daemon
    /// `modeFields` name outside the setting methods, a `params`, `_meta` or `_meta.acpmux` that is
    /// not an object, and the `_meta` of a frame that redeems a gesture ticket (R1). An unknown
    /// method is the allowlist's, never this strip's. Mirrors cmux-agent-pane-policy
    /// `stripping_unknown_params` (tests/unknown_params.rs).
    static func strippingUnknownParams(_ object: [String: Any], modeFields: Set<String>?) -> (object: [String: Any], dropped: [String])? {
        guard let method = object["method"] as? String, var params = object["params"] as? [String: Any] else { return nil }
        let known = knownParams[method] ?? ([], [])
        let setting = settingMethods.contains(method)
        let denied = setting ? [] : modeFields ?? []
        var dropped: [String] = []
        // A `_meta` that is not an object is a forged shape, not a newer key: it stays for the
        // params rule to refuse.
        for key in params.keys where !known.params.contains(key) && !denied.contains(key)
            && !(key == "_meta" && !(params[key] is [String: Any])) {
            params.removeValue(forKey: key)
            dropped.append(key)
        }
        let ticketOnly = method == "_acpmux/permission_respond" || method == "_acpmux/plan/build" || method == "chat.fix_from_link"
        if var meta = params["_meta"] as? [String: Any], !ticketOnly, !(setting && meta[gestureTicketKey] != nil) {
            let prompt = method == "session/prompt"
            for key in meta.keys where key != "acpmux" && !(prompt && key == gestureTicketKey) {
                meta.removeValue(forKey: key)
                dropped.append("_meta.\(key)")
            }
            if var acpmux = meta["acpmux"] as? [String: Any] {
                // A credential (``initializeRefusedAcpmux``) is a forgery, not a newer key: it stays
                // for the params rule to refuse.
                for key in acpmux.keys where !known.acpmux.contains(key) && !denied.contains(key)
                    && !initializeRefusedAcpmux.contains(key) {
                    acpmux.removeValue(forKey: key)
                    dropped.append("_meta.acpmux.\(key)")
                }
                meta["acpmux"] = acpmux
            }
            params["_meta"] = meta
        }
        guard !dropped.isEmpty else { return nil }
        var out = object
        out["params"] = params
        return (out, dropped.sorted())
    }

    /// P1: whether a page frame breaks the params rule. On every method: a top-level param outside
    /// the method's ``knownParams``; a `_meta` that is not an object, or that holds a key other
    /// than `acpmux`; an `acpmux` key outside the method's list. On every method except set_mode and
    /// set_config_option, also a daemon `modeFields` name at the top of params or in `acpmux`.
    /// A set_mode or set_config_option with `cmuxGesture` in `_meta` redeems a ticket: its `_meta`
    /// is the gesture rule's (R1 refuses any other key there and spends the ticket).
    static func breaksParamsRule(_ object: [String: Any]?, modeFields: Set<String>?) -> Bool {
        paramsRuleViolation(object, modeFields: modeFields) != nil
    }

    /// Which part of the params rule (P1) `object` breaks, in a few words for the relay's log and the
    /// refusal's `detail` (`unknown param "settled"`), else nil. The page shows it under the failed
    /// card's Details: a chat that cannot start says what the relay refused, not only that it did
    /// (cmux#44964; #42185 and #42460 refused an attach key and nothing named it). It names keys and
    /// rule parts only, never a param's value.
    static func paramsRuleViolation(_ object: [String: Any]?, modeFields: Set<String>?) -> String? {
        guard let object, let method = object["method"] as? String, let rawParams = object["params"] else { return nil }
        guard let params = rawParams as? [String: Any] else { return "params is not an object" }
        guard let known = knownParams[method] else {
            return params.isEmpty ? nil : "\(method) takes no params"
        }
        if let key = params.keys.sorted().first(where: { !known.params.contains($0) }) { return "unknown param \(quoted(key))" }
        if (method == "acp.trust.get" || method == "acp.trust.set"), let peer = params["peer"] {
            guard let name = peer as? String, !name.isEmpty else { return "peer is not a machine name" }
        }
        let setting = settingMethods.contains(method)
        let denied = setting ? [] : modeFields ?? []
        if let key = params.keys.sorted().first(where: denied.contains) { return "mode field \(quoted(key))" }
        guard let rawMeta = params["_meta"] else { return nil }
        guard let meta = rawMeta as? [String: Any] else { return "_meta is not an object" }
        // A redeeming frame: R1 first (nothing but the ticket in _meta), then the gesture rule.
        if setting, meta["cmuxGesture"] != nil {
            return meta.keys.sorted().first { $0 != "cmuxGesture" }.map { "unknown _meta key \(quoted($0))" }
        }
        // A permission answer's `_meta` holds the pick's ticket and nothing else, as does a plan
        // build's (it answers the plan approval).
        if method == "_acpmux/permission_respond" || method == "_acpmux/plan/build" || method == "chat.fix_from_link" {
            return Set(meta.keys) == [gestureTicketKey] ? nil : "_meta holds more than the gesture ticket"
        }
        // A prompt held for the folder trust answer redeems its ticket beside its acpmux.promptId.
        if let key = meta.keys.sorted().first(where: { $0 != "acpmux" && !(method == "session/prompt" && $0 == gestureTicketKey) }) {
            return "unknown _meta key \(quoted(key))"
        }
        guard let rawAcpmux = meta["acpmux"] else { return nil }
        guard let acpmux = rawAcpmux as? [String: Any] else { return "_meta.acpmux is not an object" }
        if let key = acpmux.keys.sorted().first(where: denied.contains) { return "mode field \(quoted(key)) in _meta.acpmux" }
        if let key = acpmux.keys.sorted().first(where: { !known.acpmux.contains($0) }) {
            return "unknown _meta.acpmux key \(quoted(key))"
        }
        if method == "_acpmux/harnesses", let peer = acpmux["peer"] {
            guard let name = peer as? String, !name.isEmpty else { return "_meta.acpmux.peer is not a machine name" }
        }
        // A start's model is a spawn parameter (Claude Code's `--model`, `${model}` in a harness's
        // argv or env): one model id, never a flag or anything else.
        if method == "session/new", let model = acpmux["model"], !isModelID(model) { return "_meta.acpmux.model is not a model id" }
        return nil
    }

    /// The `_meta.acpmux` keys an `initialize` may never carry, even as an opt-in the relay does not
    /// know: the LocalApp token is the host's alone (``withLocalAppToken(_:_:)``) and the person key
    /// never crosses the socket (cx-fcaq). They stay refused, as does a daemon `modeFields` name.
    static let initializeRefusedAcpmux: Set<String> = ["localAppToken", "personKey"]

    /// The handshake fails safe: an `initialize` with `_meta.acpmux` keys outside its known list
    /// (capability opt-ins a newer page asks for, as cmux#46563's `peerRowBatches` was) goes with
    /// those keys removed, so the daemon never sees them and answers with its default behaviour,
    /// instead of the relay refusing every connect (737+ refusals in Leo's NIGHTLY, 2026-11-21).
    /// Only those keys: a credential (``initializeRefusedAcpmux``) or a daemon mode field stays for
    /// the params rule to refuse, as do an unknown top-level param, a `_meta` key beside `acpmux`,
    /// a non-object `_meta` or `acpmux`, and every key on every other method. Nil: nothing to strip.
    static func strippingInitializeOptIns(_ object: [String: Any], modeFields: Set<String>?)
        -> (object: [String: Any], keys: [String])? {
        guard object["method"] as? String == initialize, var params = object["params"] as? [String: Any],
              var meta = params["_meta"] as? [String: Any], var acpmux = meta["acpmux"] as? [String: Any],
              let known = knownParams[initialize]?.acpmux else { return nil }
        let denied = modeFields ?? []
        let keys = acpmux.keys.filter {
            !known.contains($0) && !initializeRefusedAcpmux.contains($0) && !denied.contains($0)
        }.sorted()
        guard !keys.isEmpty else { return nil }
        for key in keys { acpmux.removeValue(forKey: key) }
        meta["acpmux"] = acpmux
        params["_meta"] = meta
        var object = object
        object["params"] = params
        return (object, keys)
    }

    /// A key as the refusal names it: quoted, at most 64 characters (a page bug can send any key).
    private static func quoted(_ key: String) -> String {
        "\"" + String(key.prefix(64)) + "\""
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
