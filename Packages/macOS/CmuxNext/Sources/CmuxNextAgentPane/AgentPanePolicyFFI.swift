import CCmuxAgentPanePolicyFFI
import Foundation

/// The agent pane's presentation and answer rules in Rust
/// (`cmux-tui/crates/cmux-agent-pane-policy`), shared by native hosts.
/// Every function may run on any thread.
nonisolated enum AgentPanePolicyFFI {
    /// The `text` of a pane-free prompt operation; nil when Rust rejected it.
    static func text(_ op: String, _ request: [String: Any]) -> String? {
        call(op, request)?["text"] as? String
    }

    /// One JSON operation with no pane handle; nil when the request is invalid
    /// or Rust could not produce a reply.
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
