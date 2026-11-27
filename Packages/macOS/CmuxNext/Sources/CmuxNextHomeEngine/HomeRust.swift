import CCmuxHomeFFI
import Foundation

/// The Home rules Rust answers (cmux-tui/crates/cmux-home-rules, linked
/// through CCmuxAppFFI as `cmux_home_call`): the decisions live there once;
/// Swift keeps the I/O (sockets, timers, tasks).
nonisolated enum HomeRust {
    /// Runs `op` (`area.name`, such as `cloud.lease_check`) on `request`
    /// and decodes the reply; nil when the op refused the request.
    static func call<Reply: Decodable>(_ op: String, _ request: some Encodable) -> Reply? {
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        var out = CmuxHomeBytes(ptr: nil, len: 0)
        let status = op.withCString { name in
            body.withUnsafeBytes { bytes in
                cmux_home_call(name, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &out)
            }
        }
        defer { cmux_home_bytes_free(out) }
        guard status == CMUX_HOME_OK, let pointer = out.ptr else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(bytes: pointer, count: out.len))
    }
}
