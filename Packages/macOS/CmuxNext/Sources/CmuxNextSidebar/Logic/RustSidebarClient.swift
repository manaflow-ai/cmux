import Foundation
import CCmuxLayoutReducerFFI

nonisolated enum RustSidebarClient {
    /// The first output buffer. A larger reply returns ERR_BUFFER with the
    /// needed length in `output_len`; the call then runs once more with a
    /// buffer of that size (a fixed 4096-byte buffer refused every larger
    /// reply, so a drop over many rows was silently refused).
    static let initialCapacity = 4096

    static func call<Request: Encodable, Response: Decodable>(_ operation: String, _ request: Request, as: Response.Type) -> Response? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            // The output buffer's own count, not `output.count`: reading `output`
            // inside its mutable-bytes closure is an overlapping access.
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
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
