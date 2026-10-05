import Foundation
#if CMUX_LAYOUT_REDUCER_FFI
import CCmuxLayoutReducerFFI
#endif

nonisolated enum RustSidebarClient {
    static func call<Request: Encodable, Response: Decodable>(_ operation: String, _ request: Request, as: Response.Type) -> Response? {
        #if CMUX_LAYOUT_REDUCER_FFI
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var output = [UInt8](repeating: 0, count: 4096); var outputLength = 0
        let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, output.count, &outputLength) } } }
        guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
        if outputLength > output.count { return nil }
        return try? JSONDecoder().decode(Response.self, from: output.prefix(outputLength))
        #else
        return nil
        #endif
    }
}
