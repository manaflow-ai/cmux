internal import CCmuxUpdaterFFI
import Foundation

/// The updater's decisions in Rust (cmux-tui/crates/cmux-app-ffi, `include/cmux_updater.h`,
/// src/updater.rs): one JSON op over `cmux_updater_call`.
nonisolated enum UpdaterRust {
    /// `op` on a JSON object: its reply (`null` reads as nil), or nil when the op refused it.
    static func call(_ op: String, _ request: [String: Any]) -> Any? {
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxUpdaterBytes(ptr: nil, len: 0)
        let code = op.withCString { op in
            json.withUnsafeBytes { bytes in
                cmux_updater_call(op, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &out)
            }
        }
        defer { cmux_updater_bytes_free(out) }
        guard code == CMUX_UPDATER_OK, let pointer = out.ptr else { return nil }
        let reply = try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: out.len), options: .fragmentsAllowed)
        return reply is NSNull ? nil : reply
    }
}
