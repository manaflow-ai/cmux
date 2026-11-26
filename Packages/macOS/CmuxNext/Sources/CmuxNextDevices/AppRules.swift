internal import CCmuxLayoutReducerFFI
public import Foundation

/// One JSON call of the app FFI (`cmux_layout_reducer_json`): the Rust rules this target asks
/// (`cloud_identity_device_slots`, `cloud_identity_device_list`), and the app's (`app_themes_*`).
/// Nil when Rust does not answer.
public enum AppRules {
    /// The answer of `operation` to `request` as JSON, or nil when Rust does not answer.
    public static func ask<Answer: Decodable>(_ operation: String, _ request: some Encodable,
                                              as _: Answer.Type = Answer.self) -> Answer? {
        guard let body = try? JSONEncoder().encode(request), let data = call(operation, body) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    public static func call(_ operation: String, _ request: Data) -> Data? {
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
