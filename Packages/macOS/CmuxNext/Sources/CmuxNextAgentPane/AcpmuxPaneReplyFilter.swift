internal import CCmuxAgentPanePolicyFFI
import Foundation

/// The replies the relay filters itself (ad349): read-only requests whose reply reaches the pane
/// cut to the fields it renders, without relying on the daemon's redaction. The shapes and the cut
/// are Rust's (cmux-agent-pane-policy `reply.rs`, the `reply_shapes` of policy.json), through
/// `cmux_agent_pane_policy_filter_reply`; the set of methods that have one
/// (``AcpmuxPaneMethods/replyShapedMethods``) is generated from the same policy.json.
nonisolated extension AcpmuxPaneMethods {
    /// `reply` (the daemon's reply text) to `method` cut to its shape, with the page's id (`pageID`,
    /// raw JSON): nil when the method has no shape, so the reply goes on as it is. A reply Rust
    /// cannot read as one JSON object, or any other failure, becomes an error reply that carries
    /// none of the daemon's fields, so a filtered method never passes an unfiltered result.
    static func filteredReply(method: String, reply: String, pageID: String) -> String? {
        guard replyShapedMethods.contains(method) else { return nil }
        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        defer { cmux_agent_pane_policy_bytes_free(out) }
        var method = method, reply = reply, pageID = pageID
        let code = method.withUTF8 { method in
            reply.withUTF8 { reply in
                pageID.withUTF8 { pageID in
                    cmux_agent_pane_policy_filter_reply(method.baseAddress, method.count, reply.baseAddress, reply.count,
                                                        pageID.baseAddress, pageID.count, &out)
                }
            }
        }
        guard code == 0, let bytes = out.ptr, out.len > 0 else { return unreadableReply(pageID: pageID) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: out.len), as: UTF8.self)
    }

    /// The reply to a filtered request whose daemon reply could not be cut: an internal error with
    /// the page's id, so the page's request still ends.
    static func unreadableReply(pageID: String) -> String {
        "{\"error\":{\"code\":-32603,\"message\":\"reply filter failed\"},\"id\":\(pageID),\"jsonrpc\":\"2.0\"}"
    }
}
