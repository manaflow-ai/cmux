internal import CCmuxLayoutReducerFFI
package import Foundation

/// The feed push rules the approve check needs, in Rust (cmux-tui/crates/cmux-feed-push-core, RFD
/// 0213 slice 1a; it was the Swift package Packages/Shared/CmuxFeedPushCore): the canonical shown
/// text's sha256 and the bytes a phone's presence key signs, over the app FFI's JSON channel
/// (`cmux_layout_reducer_json`, ops `feed_push_<op>`). The phones answer the same ops through
/// cmux-mobile-ffi's `feed_push_json`, so both sides hash and sign one definition. Nil when Rust
/// does not answer; the callers then refuse (an allow needs a match).
package struct FeedPushRules {
    /// One `cmux_layout_reducer_json` call: the op and its request JSON in, the reply JSON out.
    private let call: (String, Data) -> Data?

    /// The rules over the app FFI; `call` replaces it (tests).
    package init(call: @escaping (String, Data) -> Data? = Self.appFFI) {
        self.call = call
    }

    /// Lowercase hex sha256 of the canonical shown text of a feed item's `prompt.action`
    /// (`feed_push_shown_text`).
    package func shownSHA256(action: [String: Any]) -> String? {
        reply("shown_text", ["action": action])?["sha256"] as? String
    }

    /// The bytes a presence key signs for one approve answer (`feed_push_approve_message`).
    package func approveMessage(environment: String, user: String, phoneInstall: String, macInstall: String,
                               item: String, shownSHA256: String, decision: String, scope: String,
                               timestampMs: Int64) -> Data? {
        let request: [String: Any] = [
            "environment": environment, "user": user, "phone_install": phoneInstall, "mac_install": macInstall,
            "item": item, "shown_sha256": shownSHA256, "decision": decision, "scope": scope,
            "timestamp_ms": timestampMs,
        ]
        guard let text = reply("approve_message", request)?["text"] as? String else { return nil }
        return Data(text.utf8)
    }

    private func reply(_ op: String, _ request: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let answer = call("feed_push_" + op, data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
    }

    /// One `cmux_layout_reducer_json` call, retried once at the size it asks for.
    nonisolated package static func appFFI(_ operation: String, _ request: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}
