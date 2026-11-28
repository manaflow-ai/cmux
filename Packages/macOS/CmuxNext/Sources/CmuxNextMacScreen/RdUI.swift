import CCmuxRdFFI
import Foundation

/// Mac Screen and cmux Remote's app rules, decided in Rust (crate cmux-rd-ffi, `ui/`): one JSON op
/// in (`{"op": "<area>.<name>", "args": {...}}`), its answer out. Rust answers string keys, never
/// words: the views localize them here.
nonisolated enum RdUI {
    /// The op's answer (its `ok` value), nil when Rust refused it (an `err`) or the call failed.
    static func call(_ op: String, _ args: [String: Any] = [:]) -> Any? {
        answer(op, args).ok
    }

    /// The op with Codable args (a control request's params), as `call`.
    static func call(_ op: String, encoding args: some Encodable) -> Any? {
        answer(op, encoding: args).ok
    }

    /// The op with Codable args, as `answer`.
    static func answer(_ op: String, encoding args: some Encodable) -> (ok: Any?, err: String?) {
        guard let data = try? JSONEncoder().encode(args),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, "bad request") }
        return answer(op, object)
    }

    /// An answer's JSON value as a Codable type (a daemon `JSONValue`), nil when it does not read as one.
    static func decode<T: Decodable>(_ value: Any?, as type: T.Type = T.self) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The op's `ok` value, or its refusal's text (`err`).
    static func answer(_ op: String, _ args: [String: Any] = [:]) -> (ok: Any?, err: String?) {
        guard let request = try? JSONSerialization.data(withJSONObject: ["op": op, "args": args]) else { return (nil, "bad request") }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = request.withUnsafeBytes { raw in
            cmux_rd_ui_call(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &out, &length)
        }
        guard code == 0, let out else { return (nil, "cmux_rd_ui_call failed (\(code))") }
        defer { cmux_rd_ui_free(out, length) }
        let reply = (try? JSONSerialization.jsonObject(with: Data(bytes: out, count: length))) as? [String: Any]
        return (reply?["ok"], reply?["err"] as? String)
    }
}
