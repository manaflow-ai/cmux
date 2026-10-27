import CCmuxLayoutReducerFFI
import Foundation

/// The per-key focus rules that stay JSON calls into `cmux-focus-core`
/// (`focus_type_ahead`, `focus_child_window_key`): one call per queued key or
/// child-window key change, not per focus event.
public nonisolated struct FocusReducer {
    public nonisolated init() {}

    /// The first output buffer: a reply that does not fit returns ERR_BUFFER
    /// with the needed length, and the call runs once more with that size.
    private static let initialCapacity = 4 * 1024

    public static func call<Request: Encodable, Response: Decodable>(_ operation: String, _ request: Request,
                                                             as: Response.Type) -> Response? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            // The output buffer's own count, not `output.count`: reading
            // `output` inside its mutable-bytes closure is an overlapping access.
            // SAFETY: each buffer views its own storage (the request's data.count bytes, the operation's C string, the
            // output's outputBytes.count bytes), valid for its closure; the reducer reads and writes within those
            // counts and the local `outputLength` during the call and keeps no pointer.
            let code: Int32 = unsafe data.withUnsafeBytes { requestBytes in
                unsafe operation.withCString { operationCString in
                    unsafe output.withUnsafeMutableBytes { outputBytes in
                        unsafe cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString,
                                                        outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return try? JSONDecoder().decode(Response.self, from: Data(output.prefix(outputLength)))
        }
        return nil
    }
}
