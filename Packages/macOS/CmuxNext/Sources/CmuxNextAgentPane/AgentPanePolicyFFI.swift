import CCmuxAgentPanePolicyFFI
import Foundation

/// The agent pane's relay rules in Rust (cmux-tui/crates/cmux-agent-pane-policy, C module
/// `CCmuxAgentPanePolicyFFI` in the app FFI): this host asks them instead of keeping a Swift copy.
/// Every function may run on any thread.
nonisolated enum AgentPanePolicyFFI {
    /// The methods whose replies the relay cuts to the fields the pane renders (policy.json
    /// `reply_shapes`). nil when the policy could not be read: every reply then asks the filter.
    static let replyShapeMethods: Set<String>? = (call("policy", [:])?["reply_shape_methods"] as? [String]).map(Set.init)

    /// Whether a reply to `method` is cut to a shape (``filteredReply(method:reply:pageID:)``).
    static func hasReplyShape(_ method: String) -> Bool {
        replyShapeMethods?.contains(method) ?? true
    }

    /// A daemon reply (`reply`, one JSON object) to `method`, rebuilt with the page's id (`pageID`,
    /// raw JSON) and only the fields of its result the pane renders, at every depth; an error keeps
    /// only its code and message. nil when the method has no shape or the reply is not an object.
    static func filteredReply(method: String, reply: String, pageID: String) -> String? {
        let method = Array(method.utf8), reply = Array(reply.utf8), pageID = Array(pageID.utf8)
        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        let code = method.withUnsafeBufferPointer { method in
            reply.withUnsafeBufferPointer { reply in
                pageID.withUnsafeBufferPointer { pageID in
                    cmux_agent_pane_policy_filter_reply(method.baseAddress, method.count, reply.baseAddress, reply.count,
                                                        pageID.baseAddress, pageID.count, &out)
                }
            }
        }
        defer { cmux_agent_pane_policy_bytes_free(out) }
        guard code == 0, let bytes = out.ptr else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: out.len), as: UTF8.self)
    }

    /// The `text` of a pane-free op's reply (the `prompt_*` text ops); nil when it could not run.
    static func text(_ op: String, _ request: [String: Any]) -> String? {
        call(op, request)?["text"] as? String
    }

    /// One JSON op that needs no pane (`cmux_agent_pane_policy_call` with no handle); nil when the
    /// request is not JSON or Rust refused it.
    static func call(_ op: String, _ request: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        let code = data.withUnsafeBytes { raw in
            op.withCString { name in
                cmux_agent_pane_policy_call(nil, name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
            }
        }
        defer { cmux_agent_pane_policy_bytes_free(out) }
        guard code == 0, let bytes = out.ptr, out.len > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: out.len))) as? [String: Any]
    }
}
