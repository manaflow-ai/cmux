import Foundation

/// The params rule (P1) of ``AcpmuxPaneMethods``: each method's own param schema.
nonisolated extension AcpmuxPaneMethods {
    /// The params rule (P1), on every path: each method's top-level params and `_meta.acpmux` keys,
    /// exactly as the pane sends them (`webviews/src/agent-session/acpmux`). This is the pane's own
    /// param schema, not a mode list. The daemon's `modeFields` are an extra deny inside it.
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
        // `cwd`: the chat folder whose folder harness profiles to list (checked like every cwd).
        "_acpmux/harnesses": (["cwd"], []),
        "_acpmux/models": ([], []),
        "_acpmux/status": ([], []),
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
        // A prompt held for the folder trust answer redeems its ticket beside its acpmux.promptId.
        if meta.keys.contains(where: { $0 != "acpmux" && !(method == "session/prompt" && $0 == gestureTicketKey) }) { return true }
        guard let rawAcpmux = meta["acpmux"] else { return false }
        guard let acpmux = rawAcpmux as? [String: Any] else { return true }
        return acpmux.keys.contains(where: { !known.acpmux.contains($0) || denied.contains($0) })
    }
}
