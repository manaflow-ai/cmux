import Foundation

/// The params rule (P1) of ``AcpmuxPaneMethods``: each method's own param schema. The schema itself
/// (`knownParams`: each method's top-level params and `_meta.acpmux` keys, exactly as the pane sends
/// them) is generated from cmux-agent-pane-policy policy.json at build time (AgentPanePolicyPlugin).
nonisolated extension AcpmuxPaneMethods {
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
            for key in meta.keys where key != "acpmux" && key != traceparentKey && !(prompt && key == gestureTicketKey) {
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
        if let key = meta.keys.sorted().first(where: { $0 != "acpmux" && $0 != traceparentKey && !(method == "session/prompt" && $0 == gestureTicketKey) }) {
            return "unknown _meta key \(quoted(key))"
        }
        if let traceparent = meta[traceparentKey], !isTraceparent(traceparent) { return "_meta.traceparent is not a W3C traceparent" }
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

    /// The one `_meta` key besides `acpmux` any request may carry: the W3C trace context of the
    /// user action that sent it (one trace id per action, cmux#55505), which acpmux writes into its
    /// `CMUX_TRACE_FILE` trace. Mirrors cmux-agent-pane-policy `TRACEPARENT_KEY`.
    static let traceparentKey = "traceparent"

    /// `00-<32 hex trace id>-<16 hex parent id>-<2 hex flags>`, lowercase, nothing else.
    static func isTraceparent(_ value: Any) -> Bool {
        guard let text = value as? String, text.utf8.count == 55 else { return false }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [2, 32, 16, 2] else { return false }
        return parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
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
