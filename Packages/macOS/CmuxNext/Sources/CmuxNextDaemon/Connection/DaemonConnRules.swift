internal import CCmuxDaemonConnFFI
import Foundation

/// The JSON ops of the control connection's rules in Rust (cmux-tui/crates/cmux-daemon-conn-core,
/// `cmux_daemon_conn.h`, src/ops.rs). A request is a JSON object; a reply is one too, or nil when the op
/// refused it (a code other than 0: a null pointer, invalid input, an unknown op or a caught panic).
enum DaemonConnRules {
    /// One op with no handle (`cmux_daemon_conn_call`).
    static func call(_ op: String, _ request: [String: Any] = [:]) -> [String: Any]? {
        reply(request) { bytes, count, out in cmux_daemon_conn_call(op, bytes, count, out) }
    }

    /// One op on a command scope (`cmux_daemon_scope_call`).
    static func call(_ scope: OpaquePointer, _ op: String, _ request: [String: Any] = [:]) -> [String: Any]? {
        reply(request) { bytes, count, out in cmux_daemon_scope_call(scope, op, bytes, count, out) }
    }

    private static func reply(
        _ request: [String: Any],
        _ body: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<CmuxDaemonConnBytes>) -> Int32
    ) -> [String: Any]? {
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxDaemonConnBytes(ptr: nil, len: 0)
        let code = json.withUnsafeBytes { bytes in
            body(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &out)
        }
        defer { cmux_daemon_conn_bytes_free(out) }
        guard code == 0, let pointer = out.ptr else { return nil }
        let data = Data(bytes: pointer, count: out.len)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
