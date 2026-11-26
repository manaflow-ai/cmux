import CCmuxUpdaterFFI
import Foundation

/// The updater's decisions Rust answers (cmux-tui/crates/cmux-app-ffi/src/updater.rs, linked
/// through CCmuxAppFFI as `cmux_updater_call`): the install gate's state machine lives there once;
/// this module keeps Sparkle, AppKit and the phases' payloads.
nonisolated enum UpdaterRust {
    /// Why an op gave no reply: a bad request or an op this library does not have.
    struct Failure: Error, Sendable, Equatable {
        let status: Int32
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Runs `op` on `request` and decodes the reply as `Reply`.
    static func call<Reply: Decodable>(_ op: String, _ request: some Encodable, as _: Reply.Type = Reply.self) throws -> Reply {
        let body = try Array(encoder.encode(request))
        var out = CmuxUpdaterBytes(ptr: nil, len: 0)
        let status = op.withCString { operation in
            body.withUnsafeBufferPointer { bytes in
                cmux_updater_call(operation, bytes.baseAddress, bytes.count, &out)
            }
        }
        defer { cmux_updater_bytes_free(out) }
        guard status == 0, let pointer = out.ptr else { throw Failure(status: status) }
        return try decoder.decode(Reply.self, from: Data(bytes: pointer, count: out.len))
    }
}
