import CCmuxLayoutReducerFFI
public import Foundation

/// One JSON call of the layout reducer (`cmux_layout_reducer_json` of the app FFI) for the drag's rules
/// (`tab_drag_rule_*`, `tab_moves_*`, `drop_overlay_*`: cmux-layout-reducer `tab_drag_rules.rs`,
/// `drop_overlay_geometry.rs`, with their tests). Nil when the reducer does not answer (a pinned FFI from
/// before the op): each caller has its own safe answer then. Quiet on purpose: the overlay asks per
/// frame, and a log line per frame would flood.
public nonisolated struct LayoutReducerJSON: Sendable {
    public init() {}

    /// A reply that does not fit returns ERR_BUFFER with the needed length; the call runs once more with it.
    private static let initialCapacity = 512

    public func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request,
                                                          as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = call(operation, json: data) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: reply)
    }

    private func call(_ operation: String, json data: Data) -> Data? {
        var capacity = Self.initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            // The buffer's own count, not `output.count`: reading `output` inside its mutable-bytes
            // closure is an overlapping access.
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
