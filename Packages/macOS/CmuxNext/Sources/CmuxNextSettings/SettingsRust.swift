import CCmuxSettingsFFI
import Foundation

/// The settings reads Rust answers (cmux-tui/crates/cmux-config/src/app_ops, linked through
/// CCmuxAppFFI as `cmux_settings_call`): parse, validation and defaults live there once; this
/// module keeps the AppKit apply side.
public nonisolated struct SettingsRust {
    public nonisolated init() {}
    /// Why an op gave no reply: a bad request or an op this library does not have.
    public struct Failure: Error, Sendable, Equatable {
        public let status: Int32
    }

    /// Runs `op` on `request` and decodes the reply.
    ///
    /// - Parameters:
    ///   - op: The op's name, such as `jsonc.parse`.
    ///   - request: A JSON object.
    /// - Returns: The reply object.
    public static func call(_ op: String, _ request: JSONValue) throws -> JSONValue {
        let body = Array(request.compactText.utf8)
        var out = CmuxSettingsBytes(ptr: nil, len: 0)
        let status = op.withCString { operation in
            body.withUnsafeBufferPointer { bytes in
                cmux_settings_call(operation, bytes.baseAddress, bytes.count, &out)
            }
        }
        defer { cmux_settings_bytes_free(out) }
        guard status == 0, let pointer = out.ptr else { throw Failure(status: status) }
        return try JSONValue.parse(Data(bytes: pointer, count: out.len))
    }

    /// ``call(_:_:)`` for an op whose request is well formed by construction: a failure is a
    /// programming error, answered as `{}`.
    public static func answer(_ op: String, _ request: JSONValue) -> JSONValue {
        (try? call(op, request)) ?? .object([:])
    }
}
