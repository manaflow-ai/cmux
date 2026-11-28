import CCmuxLayoutReducerFFI
import Foundation

/// Where a relaunched tab's saved back/forward entries sit around the engine's own list, answered by
/// Rust (cmux-tui/crates/cmux-browser-rules `restored_history.rs`, with its tests) over the app FFI's
/// JSON channel (`cmux_layout_reducer_json`, ops `browser_rules_restored_history_*`). Swift keeps the
/// entries; Rust says in what order they go.
nonisolated enum BrowserRestoredHistoryRules {
    /// Where an entry of the answer comes from.
    struct Slot: Decodable, Equatable {
        enum Source: String, Decodable { case back, own, forward }
        var source: Source
        var index: Int
    }

    /// The entries in order, and the index of the engine's current one.
    struct Arrangement: Decodable, Equatable {
        var slots: [Slot]
        var current: Int
    }

    /// Where the engine's current entry (`current` in its own list) sits among the merged entries;
    /// nil when the library does not answer.
    static func position(back: Int, forward: Int, current: Int) -> Int? {
        call("position", ["back": back, "forward": forward, "current": current], as: Int.self)
    }

    static func merged(back: Int, forward: Int, count: Int, current: Int) -> Arrangement? {
        call("merged", ["back": back, "forward": forward, "count": count, "current": current], as: Arrangement.self)
    }

    /// `hasUrl`: for each of the engine's entries, whether it has a URL (one without cannot be saved).
    static func session(back: Int, forward: Int, hasUrl: [Bool], current: Int) -> Arrangement? {
        call("session", ["back": back, "forward": forward, "hasUrl": hasUrl, "current": current], as: Arrangement.self)
    }

    private static func call<Reply: Decodable>(_ name: String, _ request: [String: Any], as: Reply.Type) -> Reply? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = callData("browser_rules_restored_history_" + name, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else { return nil }
        return decoded
    }

    /// One `cmux_layout_reducer_json` call, retried once at the size it asks for.
    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }
}
