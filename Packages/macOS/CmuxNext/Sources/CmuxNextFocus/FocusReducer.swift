import CCmuxLayoutReducerFFI
public import Foundation

/// The rules that stay JSON calls into `cmux-focus-core` over the app FFI:
/// the per-key focus rules (`focus_type_ahead`, `focus_child_window_key`, one
/// call per queued key or child-window key change, not per focus event) and the
/// agent cursor visibility (`agent_cursor_visibility`, through `call(_:json:)`).
public nonisolated struct FocusReducer {
    public nonisolated init() {}

    /// The first output buffer: a reply that does not fit returns ERR_BUFFER
    /// with the needed length, and the call runs once more with that size.
    private static let initialCapacity = 4 * 1024

    public static func call<Request: Encodable, Response: Decodable>(_ operation: String, _ request: Request,
                                                             as: Response.Type) -> Response? {
        guard let data = try? JSONEncoder().encode(request), let reply = call(operation, json: data) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: reply)
    }

    /// One call with the request's JSON bytes as they are; the reply's JSON
    /// bytes, or nil when the operation refused the request.
    public static func call(_ operation: String, json data: Data) -> Data? {
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            // The output buffer's own count, not `output.count`: reading
            // `output` inside its mutable-bytes closure is an overlapping access.
            let code: Int32 = data.withUnsafeBytes { requestBytes in
                operation.withCString { operationCString in
                    output.withUnsafeMutableBytes { outputBytes in
                        cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString,
                                                 outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength)
                    }
                }
            }
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
