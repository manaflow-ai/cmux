import CCmuxLayoutReducerFFI
import Foundation

/// The updater's pure rules, owned by Rust (`cmux-tui/crates/cmux-updater-core`) and reached
/// in-process over the app FFI's JSON channel (`cmux_layout_reducer_json`, its `updater_*`
/// operations). Not a hot path: each call runs once per check, click or settings read.
nonisolated struct UpdaterRules: Sendable {
    /// The first output buffer; a larger answer returns ERR_BUFFER with its length, and the call
    /// runs once more with that size.
    static let initialCapacity = 64 * 1024

    init() {}

    /// `request` as JSON to `operation`; the decoded answer, or nil when the library refuses the
    /// request or does not know the operation.
    func call<Response: Decodable>(_ operation: String, json request: some Encodable) -> Response? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return call(operation, bytes: data)
    }

    /// `data` as the raw request of `operation` (`updater_pulled_decode` reads the body itself).
    func call<Response: Decodable>(_ operation: String, bytes data: Data) -> Response? {
        var capacity = Self.initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in
                operation.withCString { name in
                    output.withUnsafeMutableBytes { outputBytes in
                        cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, name,
                                                 outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count,
                                                 &outputLength)
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
