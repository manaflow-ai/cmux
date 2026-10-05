import Foundation
#if CMUX_LAYOUT_REDUCER_FFI
import CCmuxLayoutReducerFFI
#endif

nonisolated enum RustSidebarClient {
    static func call<Request: Encodable, Response: Decodable>(_ operation: String, _ request: Request, as: Response.Type) -> Response? {
        #if CMUX_LAYOUT_REDUCER_FFI
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        let capacity = 4096
        var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
        // The output buffer's own count, not `output.count`: reading `output`
        // inside its mutable-bytes closure is an overlapping access.
        let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
        guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
        if outputLength > capacity { return nil }
        return try? JSONDecoder().decode(Response.self, from: Data(output.prefix(outputLength)))
        #else
        return nil
        #endif
    }
}
