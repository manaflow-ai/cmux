internal import CCmuxAgentPanePolicyFFI
import Foundation

/// The params rule (P0 strip, P1) and the answers rule of ``AcpmuxPaneMethods``, run by
/// cmux-agent-pane-policy (`params.rs`, `answers.rs`, the `frame_rules` op) on the frame the relay
/// parsed. Swift keeps only the call: the pane's state (mode fields, the pending question's keys)
/// goes in, the stripped frame and the rule broken come back.
nonisolated extension AcpmuxPaneMethods {
    /// The answers rule's bounds (policy.json `question_answers`), which the question reply parser
    /// stays inside.
    static let maximumAnswerItems = 64
    static let maximumAnswerListStrings = 64
    static let maximumAnswerBytes = 4096
    static let maximumAnnotationBytes = 65536

    struct FrameRules {
        /// The frame as the strips left it; nil when they changed nothing.
        var object: [String: Any]?
        var initializeKeys: [String] = []
        var dropped: [String] = []
        var paramsViolation: String?
        var answersViolation: String?
    }

    enum FrameRuleStep: String {
        case initializeOptIns = "initialize_opt_ins"
        case unknownParams = "unknown_params"
        case params
        case answers
    }

    /// `steps` in order on `object`. A frame the rules cannot read (no JSON form, a policy error)
    /// breaks the params rule, so it is refused, never passed unchecked.
    static func frameRules(_ object: [String: Any], steps: [FrameRuleStep], modeFields: Set<String>?,
                           options: AcpmuxPermissionOptions? = nil) -> FrameRules {
        let failed = FrameRules(paramsViolation: "frame rules unavailable")
        var request: [String: Any] = ["frame": object, "steps": steps.map(\.rawValue)]
        if let modeFields { request["mode_fields"] = modeFields.sorted() }
        if let options, let params = object["params"] as? [String: Any],
           let permission = params["permissionId"] as? String,
           let keys = options.questionKeys(permissionId: permission) {
            request["question_keys"] = keys.sorted()
        }
        guard JSONSerialization.isValidJSONObject(request),
              let body = try? JSONSerialization.data(withJSONObject: request) else { return failed }
        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        defer { cmux_agent_pane_policy_bytes_free(out) }
        let code = body.withUnsafeBytes { raw in
            cmux_agent_pane_policy_call(nil, "frame_rules", raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        guard code == 0, let bytes = out.ptr, out.len > 0,
              let reply = (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: out.len))) as? [String: Any]
        else { return failed }
        return FrameRules(object: reply["frame"] as? [String: Any],
                          initializeKeys: reply["initialize_keys"] as? [String] ?? [],
                          dropped: reply["dropped"] as? [String] ?? [],
                          paramsViolation: reply["params"] as? String,
                          answersViolation: reply["answers"] as? String)
    }

    /// P0: `object` without the keys its method's lists do not name, and those keys' paths, sorted;
    /// nil when it names none.
    static func strippingUnknownParams(_ object: [String: Any], modeFields: Set<String>?) -> (object: [String: Any], dropped: [String])? {
        let rules = frameRules(object, steps: [.unknownParams], modeFields: modeFields)
        return rules.object.map { ($0, rules.dropped) }
    }

    /// An `initialize` without the `_meta.acpmux` opt-ins this app does not know; nil when it has none.
    static func strippingInitializeOptIns(_ object: [String: Any], modeFields: Set<String>?)
        -> (object: [String: Any], keys: [String])? {
        let rules = frameRules(object, steps: [.initializeOptIns], modeFields: modeFields)
        return rules.object.map { ($0, rules.initializeKeys) }
    }

    static func breaksParamsRule(_ object: [String: Any]?, modeFields: Set<String>?) -> Bool {
        paramsRuleViolation(object, modeFields: modeFields) != nil
    }

    /// Which part of the params rule the frame breaks (a key, never a value); nil when it keeps it.
    static func paramsRuleViolation(_ object: [String: Any]?, modeFields: Set<String>?) -> String? {
        guard let object else { return nil }
        return frameRules(object, steps: [.params], modeFields: modeFields).paramsViolation
    }

    static func breaksAnswersRule(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> Bool {
        answersRuleViolation(object, options: options) != nil
    }

    /// Which part of the answers rule the frame breaks (never an answer); nil when it keeps it.
    static func answersRuleViolation(_ object: [String: Any]?, options: AcpmuxPermissionOptions) -> String? {
        guard let object else { return nil }
        let rules = frameRules(object, steps: [.answers], modeFields: nil, options: options)
        return rules.answersViolation ?? rules.paramsViolation
    }
}
