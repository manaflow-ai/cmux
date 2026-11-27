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
        return call(operation, json: data, as: Response.self)
    }

    /// `call(_:_:as:)` with the request's JSON already made (a request that carries JSON the caller holds as bytes,
    /// such as a `sidebar.apply` op array, which no `Encodable` value round-trips exactly).
    static func call<Response: Decodable>(_ operation: String, json data: Data, as: Response.Type) -> Response? {
        guard let reply = reply(operation, json: data) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: reply)
    }

    /// The reply's JSON bytes of one call with the request's JSON already made; nil when the reducer refuses it.
    static func reply(_ operation: String, json data: Data) -> Data? {
        SidebarPerfCounters.add(.ffiCalls)
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
            return Data(output.prefix(outputLength))
        }
        return nil
    }

    /// What a drag handle's move answered (`cmux_sidebar_drag_*`): a reply, the same reply as last time, or a failure.
    enum HandleReply<Response> { case value(Response), same, failed }

    /// Runs one drag-handle move (`call` gets the output buffer, its capacity and the reply length), retrying once
    /// with a buffer of the needed size, as `call(_:_:as:)` does.
    static func move<Response: Decodable>(as: Response.Type, _ call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> Int32) -> HandleReply<Response> {
        SidebarPerfCounters.add(.ffiCalls)
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code = output.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &outputLength) }
            if code == CMUX_SIDEBAR_DRAG_SAME { return .same }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity,
                  let response = try? JSONDecoder().decode(Response.self, from: Data(output.prefix(outputLength))) else { return .failed }
            return .value(response)
        }
        return .failed
    }

    /// A drag handle from `request`'s JSON (`new` is `cmux_sidebar_drag_new` or `cmux_sidebar_tab_drag_new`); nil when
    /// the request does not encode or the reducer refuses it.
    static func handle<Request: Encodable, Handle>(_ request: Request, _ new: (UnsafePointer<UInt8>?, Int) -> Handle?) -> Handle? {
        SidebarPerfCounters.add(.ffiCalls)
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return data.withUnsafeBytes { new($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }
}
